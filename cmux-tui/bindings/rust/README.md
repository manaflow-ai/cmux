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

`client.process_info(surface)` returns the daemon-owned PID, exact argv vector,
current cwd, and canonical PTY name.

On the trusted local socket, `client.ensure_terminal(...)` creates or
reconnects one stable terminal UUID. `EnsureTerminalOptions::wait_after_command`
retains its final VT state after child exit until explicit close and is
creation-only.
`client.reparent_terminal(...)` moves the same identity without replacing its
PTY or child process.

## Protocol v8 topology

`identify().topology_cursor()` uses `canonical_topology_revision`. The separate
`topology_revision` field remains the protocol-v7 tree revision.

```rust
use cmux_client::{TopologyStreamEvent, TopologySubscribeOutcome};

let snapshot = client.topology_snapshot()?;
match client.subscribe_topology(snapshot.cursor())? {
    TopologySubscribeOutcome::Subscribed { mut stream, .. } => {
        match stream.recv()? {
            TopologyStreamEvent::Delta(delta) => println!("revision {}", delta.revision),
            TopologyStreamEvent::ResnapshotRequired(_) => {
                // Fetch topology_snapshot() again.
            }
        }
        stream.close();
    }
    TopologySubscribeOutcome::ResnapshotRequired(_) => {
        // Fetch topology_snapshot() again.
    }
}
```

The methods require protocol 8 and all three topology capabilities. UUIDs are
strict lowercase value types. A mismatched daemon, session, or adjacent
revision returns `ResnapshotRequired` and closes the stream. `ping()` returns
both revisions and the full session/process authority.

`ClientConfig::default()` uses `CMUX_TUI_SOCKET` when set, then legacy
`CMUX_MUX_SOCKET`, then the default session socket path.

Default derivation uses `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; empty values are ignored. On Darwin, paths over 103 filesystem bytes fall back to `/tmp/cmux-tui-<uid>` and are never truncated.

## E2E

```bash
cd cmux-tui
CMUX_TUI_SOCKET=/path/to/session.sock cargo run -p cmux-client --example e2e --locked
```
