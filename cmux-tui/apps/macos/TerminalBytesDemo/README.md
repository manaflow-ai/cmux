# TerminalBytesDemo

This macOS 14 SwiftUI app attaches one cmux PTY through the versioned
`terminal-bytes-v1` service. Rust owns invitation enrollment, Noise,
resumable lanes, Iroh, CMTH framing, and a local libghostty parser. Swift owns
the native window, visible-viewport selection, keyboard input, paste, and cell
resize reporting. It does not link or launch the full cmux macOS app.

From the `cmux-tui` directory, run:

```sh
./apps/macos/TerminalBytesDemo/run-demo.sh
```

The launcher builds `target/debug/cmux-tui`,
`target/debug/libcmux_terminal_client.a`, the Swift executable, and its
localized resource bundle, then wraps the executable and localized resources
in an ad-hoc-signed temporary `.app`.
It starts a
fresh `--iroh` daemon with mux, admin, link, and state paths
under one `mktemp` directory. The state is durable only for the demo lifetime,
which enables the per-PTY host required by `terminal-bytes-v1`. It creates a
new workspace and invitation, launches
the app with the invitation file and stable `term_…` ID prefilled, waits for the
app to claim that exact invitation ID, then approves only that ID. Closing the
app stops the daemon and removes the temporary directory. It never discovers
or connects to the ambient cmux session.

Verification:

1. The `TerminalBytes over Iroh` banner text should appear before live bytes.
2. Type `printf '\e[32mraw stream works\e[0m\n'` and press Return. The control
   sequence should produce `raw stream works`, and the raw counters
   should increase without a server snapshot RPC.
3. Resize the window, paste Japanese text, and select text. The PTY dimensions
   in diagnostics should change while selection remains local.
4. Diagnostics should report `carrier: "iroh"`,
   `service: "terminal-bytes-v1"`, the requested `terminal`, `ready: true`,
   `resync_count: 0`, and a numeric `generation`.
   `snapshot_boundary` is the authoritative parser boundary; later
   `local_parser_cursor` and `raw_frames` prove that raw PTY bytes are being
   parsed in the app. `server_snapshot_rpc_count` remains zero.

The build requires Rust 1.97.1, the Zig version declared by Ghostty, the Swift
toolchain, `jq`, and OpenSSL. The Swift executable is built under the launcher's
temporary directory, so concurrent launches do not clean or share SwiftPM
artifacts. `run-demo.sh` validates `zig` from `PATH`; set `ZIG=/path/to/zig` to
select another compatible executable.

## Protocol contract

`terminal-bytes-v1` uses one Interactive service lane. Its payload is the
little-endian CMTH frame format with a 16 MiB maximum payload. A
smart attach receives `Snapshot(N)`, `Colors(N)`, then `Ready(N)`. After that
boundary, `Output`, compact `Resized`, and `Exit` frames carry contiguous
source-order cursors greater than N. The host retains at most 8 MiB or 4096
source frames, bounds each renderer queue at 8 MiB, and bounds unapplied parser
backlog at 16 MiB. A retention gap or failed published transition emits
`ResyncRequired`; this demo surfaces `resync-required` and stops applying the
old stream, then opens a fresh attach for the same stable terminal ID. Unknown frames
close only this service stream. Clients without the
smart-renderer flag retain the existing parser-ordered CMTH snapshot and replay
behavior, so mux control, process streams, legacy snapshots, and other
transports remain compatible.
