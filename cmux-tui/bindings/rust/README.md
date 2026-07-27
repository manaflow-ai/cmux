# cmux Rust SDK

Blocking Rust client for every cmux-tui protocol-v10 command and event. The
package depends only on `libc`, Serde, and `serde_json`.

```rust
use cmux_client::{ClientConfig, CmuxClient};

let mut client = CmuxClient::connect(ClientConfig::default())?;
let server = client.identify_server()?;
assert_eq!(server.protocol, 10);

let created = client.new_workspace_simple(Some("sdk-demo"), Some((80, 24)))?;
client.send_text(created.surface, "echo hello\r")?;
println!("{}", client.read_surface(created.surface)?.text);
# Ok::<(), Box<dyn std::error::Error>>(())
```

Every wire command also has one generated method and request/result models:

```rust
use cmux_client::{CmuxClient, ListClientsRequest};

# fn example(client: &mut CmuxClient) -> cmux_client::Result<()> {
let clients = client.list_clients(ListClientsRequest::default())?;
# Ok(())
# }
```

`Optional<T>` preserves the three states available to optional nullable fields:
`Missing`, `Null`, and `Value(T)`. Required nullable fields use `Nullable<T>`,
so a missing required field remains a decode error. `Nullable<T>` supports
`is_null`, `as_ref`, `as_deref`, and conversion from `Option<T>`.
Optional non-null fields use `Option<T>`: `None` omits the field, `Some(T)`
encodes a value, and typed decoding rejects an explicit JSON `null`.

```rust
use cmux_client::Nullable;

let session: Nullable<String> = Some("agent-1".to_owned()).into();
assert_eq!(session.as_deref().into_option(), Some("agent-1"));

let no_session: Nullable<String> = None.into();
assert!(no_session.is_null());
```

Workspace topology helpers return the generated models without copying them:

```rust
# fn example(client: &mut cmux_client::CmuxClient, surface: u64)
#     -> cmux_client::Result<()> {
let tree = client.workspace_tree()?;
if let Some(context) = tree.find_surface(surface) {
    println!(
        "{} / {} / {}",
        context.workspace.name, context.screen.id, context.tab.title
    );
}
if let Some(active) = tree.active_live_pty() {
    println!("active PTY surface: {}", active.tab.surface);
}
# Ok(())
# }
```

`active_live_pty` is strict. It returns `None` when the active workspace,
screen, pane, or tab is absent, or when the active tab is dead or a browser.

Streams are bounded by `ClientConfig::max_frame_bytes` and
`max_queued_events`. A `StreamCloser` can close a stream from another thread
and immediately unblock `recv`.

```rust
use cmux_client::{AttachBuilder, SubscriptionBuilder};

# fn example(client: &mut cmux_client::CmuxClient, surface: u64)
#     -> cmux_client::Result<()> {
let deltas = SubscriptionBuilder::deltas().open(client)?;
let bytes = AttachBuilder::bytes(surface).initial_size(80, 24).open(client)?;
let render = AttachBuilder::render(surface).open(client)?;
let browser = AttachBuilder::browser(surface).open(client)?;
# drop((deltas, bytes, render, browser));
# Ok(())
# }
```

`ClientConfig::default()` uses `CMUX_TUI_SOCKET`, then legacy
`CMUX_MUX_SOCKET`, then the default `main` session socket.

## Authority boundary

Clients allow control, frontend, and local-admin commands by default.
Provider-authority commands return `CmuxError::AuthorityDenied` before any
socket write, including when called through `request_raw`.

External providers must opt in explicitly:

```rust
use cmux_client::{ClientConfig, CmuxClient};

let config = ClientConfig::default().with_provider_authority(true);
let mut provider_client = CmuxClient::connect(config)?;
# Ok::<(), cmux_client::CmuxError>(())
```

## Build and verify

```bash
cd cmux-tui
python3 bindings/codegen/generate.py --check --language rust
cargo test -p cmux-client --locked
```

## End-to-end test

```bash
cd cmux-tui
CMUX_TUI_SOCKET=/path/to/session.sock cargo run -p cmux-client --example e2e --locked
```
