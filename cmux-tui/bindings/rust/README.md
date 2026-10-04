# cmux Rust SDK

`cmux-sdk` exposes a handwritten blocking API for `cmux.protocol/2`. The
library crate is named `cmux` and supports Rust 1.88.

```rust
use cmux::{Client, Config, ReadScreenOptions, RunCommand};

# fn example() -> cmux::Result<()> {
let client = Client::connect(Config::default())?;
let session = client.current_session();
let workspace = session.create_workspace(Some("build".to_string()))?;
let terminal = workspace
    .resource
    .run(RunCommand::argv(["cargo", "test"])?)?;
let screen = terminal.resource.read_screen(ReadScreenOptions)?;
println!("{}", screen.text);
client.close()?;
# Ok(())
# }
```

Connection selection is explicit. `Client::connect` uses exactly the socket
path in the supplied `Config` and never redirects to a legacy path. Call
`Client::connect_with_legacy_fallback` only when compatibility with an older
hashed-session socket is required; that method opts in to trying the legacy
path after the configured path is missing or refuses the connection. Paths
from environment variables and paths supplied directly (including through a
`Config` struct literal) remain authoritative unless the caller chooses that
compatibility method. `Config` keeps its existing public fields, so struct
literals remain source-compatible.

Every ID validates one opaque prefix such as `ws_`, `pane_`, or `term_`.
Handles contain a `Client` and a tagged `Selector`: ID, current resource, or
exact name. Cloning and dropping a handle perform no I/O. `refresh` and
`close` are explicit.

Exact commands never invoke a shell:

```rust
# use cmux::RunCommand;
let exact = RunCommand::argv(["printf", "%s", "$HOME"])?;
let target_shell = RunCommand::shell("printf '%s' \"$HOME\"")?;
let chosen_shell = RunCommand::shell_executable("/bin/zsh", "echo ok")?;
# Ok::<(), cmux::Error>(())
```

`RunCommand::shell` asks the target session to select its platform shell.
`shell_executable` sends the exact argument vector `[executable, "-lc",
script]`.

Mutation methods return flat `MutationResult<T>` values with `value`,
`generation`, `revision`, and `replayed` fields. Empty-result conveniences use
the `MutationReceipt` alias, and creation conveniences expose the same metadata
and canonical `value` directly on `Created<T>`. Convenience methods create a
cryptographically random idempotency key and perform exactly one request. A
caller that may repeat a mutation supplies `MutationOptions::new("stable-key")`
to the corresponding `_with` method. The SDK never retries a mutation. A
`mutation.indeterminate` error retains its exact recovery details; inspect
resource state before deciding whether to issue a new request with a new key.
If a mutation loses its response to a timeout or disconnect,
`Error::MutationTransport` exposes its operation and exact supplied or
generated key.

Scope one call with a local deadline or cloneable cancellation signal:

```rust
# use cmux::{CancellationToken, Client, RequestOptions};
# use std::time::Duration;
# fn scoped(client: &Client) -> cmux::Result<()> {
let cancellation = CancellationToken::new();
let options = RequestOptions::new()
    .with_timeout(Duration::from_secs(1))?
    .with_cancellation(cancellation);
let ping = client.with_request_options(options, || {
    client.current_session().ping()
})?;
assert!(ping.alive);
# Ok(())
# }
```

Catalog results and snapshots are exact structs. Known types reject unknown
sibling fields; forward-compatible data appears only in catalog `extra` maps.
`Document` remains only for catalog JSON and unknown union values. Screen
layouts use typed leaf, split, stack, and viewport nodes.

Session events and terminal, browser, and sidebar attachments are owned typed
iterators. Each item exposes its decimal sequence, optional resume cursor, and
typed value. Owned `cancel` discards unread items and waits for the matching
response and canceled end state; the cloneable cancellation handle sends a
detached request for cross-thread shutdown. Terminal and sidebar attachments
yield styled render snapshots, patches, and scroll positions. Unknown union
variants retain their complete raw object.

Terminal and browser attachment `resize` and `release` methods use the
attachment connection that owns the viewer lease. Session creation recovery is
available through `session.creation().resolve(key)`. Terminal lifecycle waits
use `terminal.wait_exit(timeout_ms)` and return strict pending or exited
variants with typed exit, signal, and unknown outcomes.

Each browser frame includes `pointer_frame_seq: Option<u64>`. Mouse and wheel
options require that sequence and encode it as a decimal string. Send pointer
input only for frames whose sequence is `Some`; `None` means the frame cannot
authorize pointer input.

Destructive layout undo returns `Error::ConfirmationRequired` with a typed
preview token, revision, and panes. Retry with that token, its revision, and a
new idempotency key.

Shared state has typed calls: `Workspace::update` (title, color, icon with
`Update::Set`, `Update::Clear`, or `Update::Unchanged`), `Tab::pin`,
`Tab::unpin`, `Tab::update` (zoom, browser back and forward lists, frontend
owner), `Screen::update_column` (`ColumnUpdateOptions::pin(edge, mode)`,
`unpin()`, `width(w)`), and the per-window records of `window-records-v1`:
`Session::window_records`, `put_window_record`, and `delete_window_record`.
A window record's `expected_revision` is the record's own revision (`Some(0)`:
the record must not exist); a mismatch is `Error::Protocol` with code
`revision.conflict`.

```rust,no_run
use cmux::{ColumnEdge, ColumnMode, ColumnUpdateOptions, Update, WorkspaceUpdateOptions};
# fn state(session: cmux::Session, column: String) -> cmux::Result<()> {
let workspace = session.current_workspace();
workspace.update(WorkspaceUpdateOptions { color: Update::Set("#FF8800".into()), ..Default::default() })?;
let screen = workspace.current_screen();
screen.update_column(column, ColumnUpdateOptions::pin(ColumnEdge::Right, ColumnMode::Docked))?;
let frame = serde_json::json!({"frame": [0, 0, 1200, 800]});
let record = session.put_window_record("install-a", "window-1", frame, Some(0))?;
session.delete_window_record("install-a", "window-1", Some(record.value.revision))?;
# Ok(())
# }
```

All eight creation option types expose `correlation_key`. Values contain 1 to
128 UTF-8 bytes and remain stable across creation attempts.

`next_timeout(duration)` performs a bounded poll. `StreamPoll::TimedOut` leaves
the stream open and is distinct from `StreamPoll::End` and stream errors.

Generated low-level protocol models are isolated under `cmux::raw`:

```rust
let old_id: cmux::raw::Id = 7;
let _request = cmux::raw::PingRequest::default();
# let _ = old_id;
```

`cmux::raw::ByteAttachment` attaches one terminal in byte mode on its own
connection, the way the cmux-next app does. It advertises its capabilities
with `set-client-info` before attaching, then splits into a reader for one
thread and a `Clone + Send + Sync` writer for input (`send`), grid reports,
geometry claims and release, and detach.
`open` fails with `MissingCapability` when the daemon lacks
`view-attachment-lease-v1`, `view-attachment-detach-v1`, or
`attach-initial-size`. The SDK never reconnects; after
`AttachmentItem::Ended(reason)`, `reason.reattach()` says whether to open a
new attachment.

```rust,no_run
use cmux::raw::{AttachTarget, AttachmentItem, ByteAttachment, CellSize, ClientConfig};
# fn attach(terminal: cmux::TerminalId, generation: String) -> cmux::Result<()> {
let config = ClientConfig::default();
let target = AttachTarget::Terminal { id: terminal, generation };
let ByteAttachment { writer, mut reader, .. } =
    ByteAttachment::open(&config, target, CellSize::new(80, 24), Default::default())?;
std::thread::spawn(move || writer.send_bytes(b"ls\r"));
while let Some(item) = reader.next() {
    match item? {
        AttachmentItem::VtState(replay) | AttachmentItem::Resized(replay) => {
            let _ = (replay.data, replay.pending);
        }
        AttachmentItem::Output { data, .. } => drop(data),
        AttachmentItem::Ended(reason) => println!("ended: {reason:?}, {:?}", reason.reattach()),
        _ => {}
    }
}
# Ok(())
# }
```

`cmux::raw::Client::create_frontend_browser_tab` creates a browser tab that
the app renders (WebKit or CEF) with an idempotency key: a retry with the same
key returns the first tab with `replayed: true`. It identifies the connection
when needed and fails with `MissingCapability` before it sends anything to a
daemon without `frontend-browser-tab-keys-v1`. `write_frontend_browser_tab`
records the location the page reports. `request_raw` returns a
`cmux.protocol/2` failure as `Error::Protocol` with its code, message,
details, and retryability.

The `socket-path-hash` feature (on by default) derives the SHA-256 socket
path for session names too long for a Unix socket path. Embedders that always
pass an explicit socket path can build with `default-features = false` and
drop the `sha2` dependency; deriving such a path then returns
`Error::InvalidArgument`.

The optional `cmux-sidebar` companion provides Ratatui rendering and input
forwarding without adding Ratatui to this base crate.

Verify:

```bash
cd cmux-tui
cargo test -p cmux-sdk --locked
cargo test -p cmux-sidebar --locked
```
