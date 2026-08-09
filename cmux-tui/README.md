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
cargo run -p cmux-tui -- --headless --session agents
cargo run -p cmux-tui -- attach --session agents
cargo run -p cmux-tui -- attach --session agents --terminal <terminal-id>
cargo run -p cmux-tui -- machine-agent --session agents
```

The default session is `main`. Default sockets live at `$TMPDIR/cmux-tui-<uid>/<session>.sock`; use `--socket <path>` for an explicit path. Detach from an attached TUI with prefix `d`, which is `Ctrl-b d` by default.

`attach --terminal <id>` attaches one PTY terminal by its stable ID from `cmux terminal list`. It uses the full host terminal without the sidebar, status bar, pane border, or other tabs.

Pane layout stays tiled by default. Press `Ctrl-b g` to append a terminal to the right at two-thirds of the viewport width. The existing layout keeps its width, so a continuous horizontal scrollbar appears in the status bar. Focusing a pane reveals it with an animated viewport movement. `Alt-n` reapplies Zellij's automatic layout inside the focused horizontal column. `Ctrl-b U` undoes the latest structural layout action on the focused screen; undoing pane creation asks for confirmation before closing the pane.

The public control CLI is noun-first:

```bash
cmux workspace create --name api
cmux workspace current run -- cargo test
cmux terminal term_0123456789abcdef0123456789abcdef screen read
cmux session current events --jsonl
```

Resource IDs are opaque typed strings. Selectors also accept `current` or an exact name. Duplicate names return `selector.ambiguous` with every candidate ID; use an ID to choose one. Prefix a reserved or ID-shaped name with `name:`.

Packaged builds can run as `npx cmux`. The optional machine rail lets that local client switch among the current session, other Unix sockets, and sessions reached through SSH. It is disabled by default and activates when `machine_sidebar.enabled` is true or `machines` contains a valid entry in `cmux-tui.json`. `npx cmux --cloud` composes those local targets with the Cloud catalog and enables temporary machine connections without sending local SSH details to Cloud. The client uses noninteractive SSH with strict host-key checking and the remote `cmux relay --session <name>` transport primitive, so the remote headless session, trusted host key, authentication key, and binary must already exist. See [Machines and remote sessions](docs/machines.md).

```bash
npx cmux
npx cmux machine-agent --session agents
ssh -T dev@buildbox cmux relay --session agents
```

The Unix-only `machine-agent` shares an existing local session through one outbound SSH registration with cmux.cloud. It prints a one-time pairing code and opens no listener. The final command carries raw JSON-lines protocol traffic and is normally started by the machine connector, not used as an interactive TUI.

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; `CMUX_TUI_TERM` can override the terminal runtime default, with `CMUX_MUX_TERM` retained as a legacy fallback.

## Browser Realism

By default, browser panes launch your real Google Chrome or another Chrome-family binary in `browser.mode: "headful"` with a visible window and a persistent per-session profile. Log into Google or other sites once in that visible window; cookies and logins persist across sessions. Set `browser.mode: "headless"` to hide the launched Chrome window. Both modes keep the anti-throttle flags, `--disable-blink-features=AutomationControlled`, the persistent `--user-data-dir`, and `about:blank` startup.

Chrome 136 and newer reject CDP remote debugging on the OS-default profile directory, and a running normal Chrome owns its profile `SingletonLock`. Use the mux profile, set `browser.user_data_dir` to a copy or a dedicated directory after quitting normal Chrome, or attach to a Chrome you started with `--remote-debugging-port`.

To attach instead of launching, set `browser.cdp_url`, `CMUX_MUX_CDP_URL`, or enable discovery. Agent Browser works the same way: run `agent-browser get cdp-url` and use the returned `ws://` URL. This build supports `ws://` and `http://` CDP endpoints; `wss://` is not supported.

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
