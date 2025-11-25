//------------------------------------------------------------------------------
// ETU Confidence Test (synthesizable, integer/fixed-point)
//
// This module implements an approximate Wald-style test:
//
//   mean      = cum_val / n
//   mean_abs  = |mean|
//   m2        = mean_abs^2
//   temp      = cum_sq / n        // approx E[x^2]
//   var       = max(temp - m2, 0) // approx variance
//   left      = m2 * n
//   right     = bound_sq * var    // bound_sq = (test_stat_bound)^2
//
//   early_terminate = (left < right)
//
// All arithmetic is integer / fixed-point (2's complement).
// You choose the scaling for cum_val, cum_sq, and bound_sq.
//
// Handshake:
//   - in_valid:  inputs stable & valid this cycle
//   - out_valid: result valid next cycle
//
//------------------------------------------------------------------------------

module etu_confidence #(
    parameter DATA_W = 16,   // bit-width for cum_val, mean, etc.
    parameter SQ_W   = 32,   // bit-width for cum_sq (sum of squares)
    parameter N_W    = 8     // bit-width for sample count n
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Input handshake
    input  wire                     in_valid,

    // Statistics inputs for ONE neuron
    input  wire signed [DATA_W-1:0] cum_val,   // Σ x·w (partial sum)
    input  wire        [SQ_W-1:0]   cum_sq,    // Σ (x·w)^2
    input  wire        [N_W-1:0]    n,         // sample count (E)

    // Threshold (pre-computed): bound_sq = (test_stat_bound)^2
    // Same fixed-point scaling as mean^2.
    input  wire        [DATA_W-1:0] bound_sq,

    // Output handshake
    output reg                      out_valid,

    // Decision: 1 = early terminate this neuron
    output reg                      early_terminate
);

    // Internal combinational signals
    reg  signed [DATA_W-1:0] mean_s;
    reg         [DATA_W-1:0] mean_abs;
    reg         [2*DATA_W-1:0] m2;        // mean_abs^2

    reg         [SQ_W-1:0] temp_u;        // cum_sq / n
    reg         [DATA_W-1:0] temp_trunc;  // truncated to DATA_W

    reg         [DATA_W-1:0] var_u;       // approx variance, truncated
    reg         [2*DATA_W-1:0] left;
    reg         [2*DATA_W-1:0] right;

    reg                        res_comb;  // combinational decision

    //-------------------------------------------------------------------------
    // Combinational datapath: one-cycle arithmetic
    //-------------------------------------------------------------------------
    always @* begin
        // Default values to avoid Xs
        mean_s      = {DATA_W{1'b0}};
        mean_abs    = {DATA_W{1'b0}};
        m2          = {2*DATA_W{1'b0}};
        temp_u      = {SQ_W{1'b0}};
        temp_trunc  = {DATA_W{1'b0}};
        var_u       = {DATA_W{1'b0}};
        left        = {2*DATA_W{1'b0}};
        right       = {2*DATA_W{1'b0}};
        res_comb    = 1'b0;

        if (n != {N_W{1'b0}}) begin
            // mean = cum_val / n  (signed divide)
            mean_s = cum_val / $signed({{(DATA_W-N_W){1'b0}}, n});

            // mean_abs = |mean|
            if (mean_s[DATA_W-1] == 1'b1)
                mean_abs = ~mean_s + 1'b1; // 2's complement abs
            else
                mean_abs = mean_s;

            // m2 = mean_abs^2  (full precision in 2*DATA_W bits)
            m2 = mean_abs * mean_abs;

            // temp_u = cum_sq / n  (unsigned divide)
            temp_u = cum_sq / n;

            // Truncate temp_u down to DATA_W bits; you can change this
            // to rounding or saturation if you prefer.
            temp_trunc = temp_u[DATA_W-1:0];

            // var ≈ max(temp_trunc - m2_low, 0)
            // here we compare against lower DATA_W bits of m2
            if (temp_trunc > m2[DATA_W-1:0])
                var_u = temp_trunc - m2[DATA_W-1:0];
            else
                var_u = {DATA_W{1'b0}};

            // left  = m2 * n
            left  = m2 * {{(2*DATA_W-N_W){1'b0}}, n};

            // right = bound_sq * var
            right = {{DATA_W{1'b0}}, bound_sq} * {{DATA_W{1'b0}}, var_u};

            // early terminate if "test_stat" < bound  ⇒ left < right
            res_comb = (left < right);
        end
        else begin
            // n == 0 (should not happen); be conservative: do NOT early terminate
            res_comb = 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Output register: align result with in_valid (1-cycle latency)
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid        <= 1'b0;
            early_terminate  <= 1'b0;
        end else begin
            out_valid       <= in_valid;
            early_terminate <= res_comb;
        end
    end

endmodule


etu_confidence #(
    .DATA_W(16),
    .SQ_W  (32),
    .N_W   (8)
) etu_conf (
    .clk            (clk),
    .rst_n          (rst_n),
    .in_valid       (stats_valid),
    .cum_val        (cum_val_i),
    .cum_sq         (cum_sq_i),
    .n              (E),              // early_terminate_it
    .bound_sq       (BOUND_SQ),       // (test_stat_bound)^2 in fixed-point
    .out_valid      (etu_valid),
    .early_terminate(etu_bit_i)
);
