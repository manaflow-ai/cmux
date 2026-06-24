# Iroh iPhone to Mac Demo

This prototype connects an iPhone app to a Mac terminal app with iroh.

The Mac runs a small Ratatui TUI that starts an iroh endpoint and prints an `EndpointTicket`. The iPhone app pastes that ticket and sends typed requests over a custom iroh ALPN. The Mac replies on the same QUIC stream, logs the request, and can run a command inside a Mac pseudoterminal.

## Build the iOS Rust wrapper

```bash
./build-ios-xcframework.sh
```

This builds the Rust static library for device and simulator, then writes:

```text
iOS/IrohPhoneDemoPackage/Binaries/IrohPhoneMacFFI.xcframework
```

## Run the Mac TUI

```bash
cargo run --manifest-path rust/Cargo.toml --bin iroh-demo-tui
```

Press `c` to copy the ticket shown in the TUI. Press `q` to quit.

## Run the iPhone app

Open `iOS/IrohPhoneDemo.xcworkspace`, or build with XcodeBuildMCP after the XCFramework exists. Paste the Mac ticket into the app and tap `Ping Mac`.

The app shows ping latency, PTY command latency, and the Mac pseudoterminal output. The first request for a ticket includes connection setup. Later requests reuse the same iroh connection and open a new stream per command. If the cached connection stops responding after a network change, the next request times out, reconnects from the ticket, and retries once. The TUI logs the iPhone request.
