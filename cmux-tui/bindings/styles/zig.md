# Zig Binding Style

Requirements:

- Target Zig 0.16.0 and use only the standard library at runtime.
- Require caller-provided `std.Io` at client construction and retain it for
  transport, clocks, and synchronization.
- Require an allocator for owned clients, decoded values, streams, and provider state.
- Give every owned result an explicit `deinit`.
- Preserve exact integer widths, missing/null states, and unknown event JSON.
- Use bounded frames and pre-ack queues.
- Keep generated wire declarations separate from hand-written lifecycle helpers.
- Zero provider authority buffers and other owned secrets before freeing them.
- Preserve structured remote diagnostics without stale side-channel state.
- Pass formatting, leak-detecting tests, and external package consumption.
