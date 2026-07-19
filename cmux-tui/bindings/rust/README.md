# cmux Rust Client

Synchronous Rust client for the cmux-tui Unix-socket JSON-lines protocol.

## Build

```bash
cd cmux-tui
cargo build -p cmux-client --locked
```

## Usage

```rust
use cmux_client::{ClientConfig, CmuxClient};

let mut client = CmuxClient::connect(ClientConfig::default())?;
let surface = client.new_workspace(Some("sdk-demo"), Some(80), Some(24))?.surface;
client.send(surface, Some("echo hello\r"), None)?;
println!("{}", client.read_screen(surface)?.text);
# Ok::<(), Box<dyn std::error::Error>>(())
```

`ClientConfig::default()` uses `CMUX_TUI_SOCKET` when set, then legacy
`CMUX_MUX_SOCKET`, then the default session socket path.

## 0.3 migration

Protocol v8 adds `IdentifyResult.capabilities`, `Tree.workspace_revision`, and
`Workspace.key`. Code that constructs these public structs directly must supply
the new fields; deserialization remains compatible with older servers through
Serde defaults.

## E2E

```bash
cd cmux-tui
CMUX_TUI_SOCKET=/path/to/session.sock cargo run -p cmux-client --example e2e --locked
```
