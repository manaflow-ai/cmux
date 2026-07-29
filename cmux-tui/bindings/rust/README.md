# cmux Rust SDK

`cmux-client` exposes a handwritten blocking API for `cmux.protocol/1`. The
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
let value: serde_json::Value = screen.deserialize()?;
println!("{}", value["text"]);
client.close()?;
# Ok(())
# }
```

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

Session events and terminal, browser, sidebar, and provider attachments are
owned typed iterators. Each item exposes its decimal sequence, optional resume
cursor, and typed value. Owned `cancel` discards unread items and waits for the
matching response and canceled end state; the cloneable cancellation handle
sends a detached request for cross-thread shutdown. Terminal and sidebar
attachments yield styled render snapshots, patches, and scroll positions.
Unknown union variants retain their complete raw object. Provider notices
require an explicit `notice.acknowledge(sequence)` call after the application
paints them.

Machine-scoped provider handles expose provider-workspace mark, rename, and
close operations. They take a typed workspace handle so machine, provider,
session, and workspace routing remains explicit.

Generated low-level protocol models are isolated under `cmux::raw`:

```rust
let old_id: cmux::raw::Id = 7;
let _request = cmux::raw::PingRequest::default();
# let _ = old_id;
```

The optional `cmux-sidebar` companion provides Ratatui rendering and input
forwarding without adding Ratatui to this base crate.

Verify:

```bash
cd cmux-tui
cargo test -p cmux-client --locked
cargo test -p cmux-sidebar --locked
```
