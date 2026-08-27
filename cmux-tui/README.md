# cmux-tui

`cmux-tui` is the Rust TUI multiplexer in this repository. It keeps a tree of machines, sessions, workspaces, screens, panes, tabs, terminals, and browsers. Its public CLI and SDKs expose those resources through `cmux.protocol/2`.

## Documentation

- [Docs index](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Remote daemon and clients](docs/remote.md)
- [Remote workspace RPC contract](spec/remote-rpc.md)
- [Concepts](docs/concepts.md)
- [Keyboard](docs/keyboard.md)
- [Mouse](docs/mouse.md)
- [Configuration](docs/configuration.md)
- [Machines and remote sessions](docs/machines.md)
- [Public CLI](spec/cli.md)
- [SDK contract](spec/bindings.md)
- [Public resource protocol](spec/resource-api-v2.md)
- [Raw control protocol](docs/protocol.md)
- [Browser panes](docs/browser-panes.md)

## Build

Builds need Zig 0.16.0, a Rust toolchain, and the `ghostty` submodule initialized. The `ghostty-vt-sys` crate builds `libghostty-vt.a` from the submodule with Zig before compiling the Rust crates.

```bash
cd cmux-tui
cargo build -p cmux-tui
```

## Run

`machine-agent` is available only on Unix platforms.

```bash
cd cmux-tui
cargo run -p cmux-tui
cargo run -p cmux-tui -- --session agents
cargo run -p cmux-tui -- server start --session agents
cargo run -p cmux-tui -- server status --session agents
cargo run -p cmux-tui -- server stop --session agents
cargo run -p cmux-tui -- attach --session agents
cargo run -p cmux-tui -- attach --session agents --terminal <terminal-id>
cargo run -p cmux-tui -- machine-agent --session agents
```

The default session is `main`. Default sockets live at `$TMPDIR/cmux-tui-<uid>/<session>.sock`; use `--socket <path>` for an explicit path. Detach from an attached TUI with prefix `d`, which is `Ctrl-b d` by default.

`server start` is the canonical durable headless session command. The older
`--headless` spelling remains a compatibility alias.

`attach --terminal <id>` attaches one PTY terminal by its stable ID from `cmux terminal list`. It uses the full host terminal without the sidebar, status bar, pane border, or other tabs.

Pane layout stays tiled by default. Press `Ctrl-b g` to append a terminal to the right at two-thirds of the viewport width. The existing layout keeps its width, so a continuous horizontal scrollbar appears in the status bar. Focusing a pane reveals it with an animated viewport movement. `Alt-n` reapplies Zellij's automatic layout inside the focused horizontal column. `Ctrl-b U` undoes the latest structural layout action on the focused screen; undoing pane creation asks for confirmation before closing the pane.

The public control CLI is noun-first:

```bash
cmux workspace create --name api
cmux workspace current run -- cargo test
cmux terminal term_0123456789abcdef0123456789abcdef screen read
cmux session current events --jsonl
```

Use `cmux server start|status|stop|reload-config` for one named local durable
session. `server stop` is idempotent when absent and preserves saved topology.
Shared routing options can precede the scope, as in
`cmux --session agents server status`. Lifecycle JSON errors use stable codes
and do not expose raw transport or server error text.
Use the `remote` command group for authenticated network access:
`cmux remote connect|ssh|forward|rpc`, `remote enroll`, and
`remote known-daemons`. `remote stop` stops only a replaceable SSH sidecar.
Use `server stop` for a listener owned by `server start`; it also stops the
local owner and its workspaces. Start the owning process with `server start`
and explicit remote-listener flags.
The old top-level remote commands and `remote-stop` remain compatibility
aliases for one release cycle. Detached local startup is deferred until cmux
has an explicit supervisor and readiness contract.

Resource IDs are opaque typed strings. Selectors also accept `current` or an exact name. Duplicate names return `selector.ambiguous` with every candidate ID; use an ID to choose one. Prefix a reserved or ID-shaped name with `name:`.

Packaged builds can run as `npx cmux`. The optional machine rail lets that local client switch among the current session, Unix sockets, and SSH sessions. It is disabled by default and activates when machine sidebar settings or a valid `machines` entry enable it. Packaged releases install a pinned remote binary when needed; source builds require the exact matching binary remotely. SSH remains noninteractive with strict host-key checking and disabled forwarding. See [Machines and remote sessions](docs/machines.md).

```bash
npx cmux
npx cmux machine-agent --session agents
npx cmux ssh dev@buildbox --session agents
ssh -T dev@buildbox cmux relay --session agents
```

The Unix-only `machine-agent` shares an existing local session through one outbound SSH registration with cmux.cloud. It prints a one-time pairing code and opens no listener. The final command is a low-level raw JSON-lines diagnostic. Use the machine rail or `cmux ssh` for the managed remote lifecycle.

Upgrade a packaged install with `npx cmux update`; it downloads the latest verified binary without rewriting npm's caches. Writable launcher-cache hits revalidate the registry tarball before launch, while a fully read-only provisioned cache can run offline. `npx` can still touch, or fail while touching, npm's `_npx` cache before cmux starts. Use `npx cmux update` for routine platform-binary upgrades and `npx cmux@latest` when updating the npm launcher. If the latter fails with `ENOTEMPTY: directory not empty, rename`, see [Packaged installs and updates](docs/getting-started.md#packaged-installs-and-updates). Japanese: [npm パッケージ](README.ja.md).

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; `CMUX_TUI_TERM` can override the terminal runtime default, with `CMUX_MUX_TERM` retained as a legacy fallback.

## Browser ownership

Browser tabs are attach-only. cmux-tui never discovers or launches Chrome and never owns browser profiles, cookies, or targets. A live cmux-browser process publishes its ephemeral loopback CDP endpoint and stable tab-to-target mapping over the trusted local control socket. If that provider disappears, the canonical tab and layout remain and reconnect when the provider returns. `CMUX_MUX_CDP_URL` remains an explicit development-only endpoint.

cmux-browser starts its bundled TUI with the upstream Vercel `agent-browser` provider enabled. New terminal shells inherit a caller-local agent-browser session and a `browser.provider` plugin backed by the same cmux-browser process, so ordinary `agent-browser snapshot`, `click`, `fill`, and related commands operate on a browser tab in that terminal's canonical workspace instead of spawning or auto-discovering another Chrome. Selection is deterministic and does not read any frontend's active/focus state; set `CMUX_TUI_BROWSER_TAB_ID` to choose an exact stable tab when a workspace contains several browser tabs.

## Development

```bash
cd cmux-tui
cargo test
```

The smoke scripts expect a built `cmux-tui` binary unless `CMUX_TUI_BIN` is set.

```bash
cd cmux-tui
cargo build -p cmux-tui
python3 scripts/smoke-tui.py
python3 scripts/smoke-attach.py
```
