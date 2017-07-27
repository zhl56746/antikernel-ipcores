`timescale 1ns / 1ps
`default_nettype none
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2017 Andrew D. Zonenberg                                                                          *
* All rights reserved.                                                                                                 *
*                                                                                                                      *
* Redistribution and use in source and binary forms, with or without modification, are permitted provided that the     *
* following conditions are met:                                                                                        *
*                                                                                                                      *
*    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the         *
*      following disclaimer.                                                                                           *
*                                                                                                                      *
*    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the       *
*      following disclaimer in the documentation and/or other materials provided with the distribution.                *
*                                                                                                                      *
*    * Neither the name of the author nor the names of any contributors may be used to endorse or promote products     *
*      derived from this software without specific prior written permission.                                           *
*                                                                                                                      *
* THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   *
* TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL *
* THE AUTHORS BE HELD LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES        *
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR       *
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT *
* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE       *
* POSSIBILITY OF SUCH DAMAGE.                                                                                          *
*                                                                                                                      *
***********************************************************************************************************************/

/**
	@file
	@author Andrew D. Zonenberg
	@brief UART wrapper for RED TIN logic analyzer

	SIGNAL_ROM format:
		16384'h0,						//Padding to ensure ROM is always 16Kbits in size
		{ "DEBUGROM" }	,				//Magic header to indicate start of ROM
		32'd10000,						//Timebase, in picoseconds
		32'd512,						//Capture depth, in samples
		32'd128,						//Capture width, in samples
		{ "uart_tx_en\0", 8'h1, 8'h0 },	//name, width, format TBD (reserved zero)
		{ "uart_txd\0", 8'h8, 8'h0 },
 */
module RedTinUartWrapper #(
	parameter WIDTH = 128,
	parameter DEPTH = 512,
	parameter SYMBOL_ROM = 16384'h0,
	parameter UART_CLKDIV = 16'd868			//115200 baud @ 100 MHz
	)(

		//Internal clock, not necessarily used for capturing
		input wire				clk,

		//Data being sniffed
		input wire				capture_clk,
		input wire[WIDTH-1:0]	din,

		//Bus to host PC
		input wire				uart_rx,
		output wire				uart_tx,

		//DEBUG
		output reg[3:0]			led = 0
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Do some math to figure out how much data we need to move

	`include "../synth_helpers/clog2.vh"

	//The trigger data is one block of 32 32-bit words per 64 channels.
	//This is a total of 128 bytes per 64 channels or 2 bytes per channel.
	localparam BITSTREAM_SIZE = 2*WIDTH;
	localparam BITSTREAM_END = BITSTREAM_SIZE - 2;
	localparam BITSTREAM_ABITS = clog2(BITSTREAM_SIZE);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// The UART

	//8N1 configuration, no others supported
	reg			uart_tx_en		= 0;
	reg[7:0]	uart_tx_data	= 0;
	wire		uart_tx_active;
	wire		uart_rx_en;
	wire[7:0]	uart_rx_data;
	UART #(
		.OVERSAMPLE(1)
	) uart(
		.clk(clk),
		.clkdiv(UART_CLKDIV[15:0]),

		.tx(uart_tx),
		.tx_data(uart_tx_data),
		.tx_en(uart_tx_en),
		.txactive(uart_tx_active),

		.rx(uart_rx),
		.rx_data(uart_rx_data),
		.rx_en(uart_rx_en),
		.rxactive()
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Reshuffle the signal ROM until it fits in a 2Kx8 ROM, and swap bytes so we're ordered properly

	reg[7:0] symbols[2047:0];

	integer i;
	initial begin

		for(i=0; i<2048; i=i+1)
			symbols[i] <= SYMBOL_ROM[(2047 - i)*8 +: 8];

	end

	reg			symbol_rd_en	= 0;
	reg[10:0]	symbol_rd_addr	= 0;
	reg[7:0]	symbol_rd_data	= 0;

	always @(posedge clk) begin
		if(symbol_rd_en)
			symbol_rd_data		<= symbols[symbol_rd_addr];
	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// The actual LA

	localparam 			ADDR_BITS = clog2(DEPTH);

	reg[31:0]			reconfig_din	= 0;
	reg					reconfig_ce		= 0;
	reg					reconfig_finish	= 0;

	reg					read_en			= 0;
	reg[ADDR_BITS-1:0]	read_addr		= 0;
	wire[WIDTH-1:0]		read_data;
	wire[31:0]			read_timestamp;

	reg					la_reset		= 0;
	wire				capture_done;

	RedTinLogicAnalyzer #(
		.DEPTH(DEPTH),
		.DATA_WIDTH(WIDTH)
	) la (

		//Capture bus
		.capture_clk(capture_clk),
		.din(din),

		//Trigger bus
		.reconfig_clk(clk),
		.reconfig_din(reconfig_din),
		.reconfig_ce(reconfig_ce),
		.reconfig_finish(reconfig_finish),

		//Readout bus
		.read_clk(clk),
		.read_en(read_en),
		.read_addr(read_addr),
		.read_data(read_data),
		.read_timestamp(read_timestamp),

		//Command bus
		.done(capture_done),
		.reset(la_reset)
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// UART command engine

	`include "RedTin_opcodes_localparam.vh"

	localparam STATE_IDLE				= 4'h0;
	localparam STATE_SYMTAB_0			= 4'h1;
	localparam STATE_SYMTAB_1			= 4'h2;
	localparam STATE_RECONFIGURE		= 4'h3;
	localparam STATE_RECONFIGURE_FINISH	= 4'h4;
	localparam STATE_TRIGGERED			= 4'h5;

	reg[3:0]					state 	= STATE_IDLE;
	reg[BITSTREAM_ABITS-1:0]	bitpos	= 0;

	reg							notif_sent	= 0;

	always @(posedge clk) begin

		symbol_rd_en	<= 0;
		uart_tx_en		<= 8'h0;

		reconfig_ce		<= 0;
		reconfig_finish	<= 0;
		la_reset		<= 0;

		case(state)

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// IDLE - sit around and wait for the opcode byte to come in

			STATE_IDLE: begin

				if(uart_rx_en) begin
					case(uart_rx_data)

						//Read symbol table - dump out the ROM
						REDTIN_READ_SYMTAB: begin
							symbol_rd_en		<= 1;
							symbol_rd_addr		<= 0;
							state				<= STATE_SYMTAB_0;
						end	//end REDTIN_READ_SYMTAB

						//Load trigger - take a bunch of LUT equations and shove them into the LA
						REDTIN_LOAD_TRIGGER: begin
							la_reset			<= 1;
							bitpos				<= 0;
							state				<= STATE_RECONFIGURE;
						end	//end REDTIN_LOAD_TRIGGER

						//Unknown opcode? Ignore it
						default: begin
						end
					endcase

				end

				//Scope just triggered! Send out an alert
				if(capture_done && !notif_sent) begin
					led[3]						<= 1;
					uart_tx_en					<= 1;
					uart_tx_data				<= REDTIN_TRIGGER_NOTIF;
					notif_sent					<= 1;
				end

			end	//end STATE_IDLE

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// SYMTAB - just spam the symbol table out the UART

			//Wait for read, then send it
			STATE_SYMTAB_0: begin
				if(!symbol_rd_en) begin
					uart_tx_en		<= 1;
					uart_tx_data	<= symbol_rd_data;
					state			<= STATE_SYMTAB_1;
				end
			end	//end STATE_SYMTAB_0

			//Wait for send, then read
			STATE_SYMTAB_1: begin
				if(!uart_tx_active && !uart_tx_en) begin

					//Not done? Keep going
					if(symbol_rd_addr != 'd2047) begin
						symbol_rd_en	<= 1;
						symbol_rd_addr	<= symbol_rd_addr + 1'h1;
						state			<= STATE_SYMTAB_0;
					end

					//Done, move along
					else
						state			<= STATE_IDLE;

				end
			end	//end STATE_SYMTAB_1

			////////////////////////////////////////////////////////////////////////////////////////////////////////////
			// RECONFIGURE - load new trigger config

			STATE_RECONFIGURE: begin
				if(uart_rx_en) begin
					led[0]				<= 1;
					bitpos				<= bitpos + 1'h1;

					reconfig_din		<= { reconfig_din[23:0], uart_rx_data };

					//We read 3 bytes, 4th is just arriving now
					if(bitpos[1:0] == 2'd2)
						reconfig_ce		<= 1;

					//Just got last byte? Go tell it to commit the changes
					if(bitpos == BITSTREAM_END)
						state			<= STATE_RECONFIGURE_FINISH;

				end
			end	//end STATE_RECONFIGURE

			STATE_RECONFIGURE_FINISH: begin
				led[1]					<= 1;
				reconfig_finish			<= 1;
				notif_sent				<= 0;
				state					<= STATE_IDLE;
			end	//end STATE_RECONFIGURE_FINISH

		endcase

	end

endmodule
