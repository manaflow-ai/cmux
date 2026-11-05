# cmux-tui agent instructions

Maintainers do not run `cargo`, `rustc`, or Zig on their local Mac and do not use a local build as a fallback. Commit and push the exact branch head to manaflow-ai/cmux, then use the hosted entry point from the repository root:

```bash
./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
./scripts/verify-cmux-tui-hosted.sh --full
```

Use `--filter` during focused development. It accepts one Rust test-name substring and verifies that the filter selects at least one test on hosted Linux and macOS. The reserved `chatmux_relay` (or `chatmux-relay`) selector runs the complete `chatmux-relay` package because Cargo test names do not include package names. Use `--full` for the merge gate. Full mode runs the complete Linux and macOS suites, package builds, and a Windows-hosted binary execution check.

The script rejects dirty or unpushed work, verifies the exact commit in every hosted job, waits for completion, prints failed logs, and downloads the macOS arm64 TUI and userland agent detector to `cmux-tui/target/hosted/<commit>/cmux-tui` and `cmux-tui/target/hosted/<commit>/cmux-agent-screen-detection`. Running those downloaded binaries on the Mac is allowed.

`rust-toolchain.toml` is the single Rust toolchain source for hosted TUI tests, package builds, and live conformance. Change that file instead of adding a workflow-specific Rust version.

## Daemon edits: swap the running daemon

To try a daemon edit (`crates/cmux-tui-core`, `crates/cmux-tui`, `crates/acpmux`) on a running session,
swap the daemon for the new build. Don't end its terminals or kill it. Run the new build's own CLI:

```bash
<new build>/cmux-tui --session <name> server restart   # same as `cmux daemon restart`
<new build>/cmux-tui-acpmux daemon restart             # agent sessions
```

`server restart` stops the session's daemon the way an update hands it off, waits for it to exit,
and starts the daemon of the binary you ran. That daemon adopts every terminal: the same shells,
their scrollback and their input. `acpmux daemon restart` does the same for agent sessions, which
keep their conversation. On a Mac, the new build is the binary `verify-cmux-tui-hosted.sh` downloads
to `cmux-tui/target/hosted/<commit>/` (above). A tagged app's session is `cmux-app-<tag>`. The app
hands its session back to the daemon bundled in it on its next launch, unless that bundle carries
your build (`CMUX_NEXT_TUI_BIN=<path> scripts/reload.sh --tag <tag>`).
`scripts/cmux-next/daemon-swap-check.py --old A --new B` checks a swap between two builds end to end
(HQ#7149 L7 runs it hourly against NIGHTLYs).

## Settings in the CLI and MCP

`cmux settings` and the MCP `settings_*` tools work for every key in the embedded settings schema
(`schemas/settings/settings-schema.json`), so every app setting reaches them. Keep it that way: a change to a setting's kind, validation or value shape lands in
`crates/cmux-config/src/schema/` in the same change, and no setting gets a CLI-only or MCP-only path. See
"Settings on every surface" in the [root CLAUDE.md](../CLAUDE.md#settings-on-every-surface).

## Blacksmith Testbox

Blacksmith Testbox gives maintainers with Blacksmith access a remote Linux box for cmux-tui Rust
and Zig builds: warm your own box before the build, and never compile cmux-tui on the Mac. The
workflows, `scripts/blacksmith-*.sh`, and the `tests/test_testbox_*` guards live here. Team members
with a cmuxterm-hq checkout can run `HQ_TOOLS=<hq checkout on main> ./scripts/blacksmith-testbox-demo.sh`
for a guided tour; it starts the box through the private hq wrapper and stops without it.

Outside contributors cannot dispatch the hosted verification from a fork. Run focused `cargo test`
inside `cmux-tui/` locally (needs Zig 0.16.0 and `git submodule update --init ghostty ghostty-next`; see
`cmux-tui/README.md`) and say so in the PR; a maintainer runs the hosted verification on it.

## Running Cloud machines

Every cmux Cloud machine runs this daemon, and it is upgraded in place under the machine's original supervisor and next to terminal hosts from older builds. Before changing the daemon's command line or environment, the terminal-host protocol, SIGTERM handling, or on-disk journal/registry schema, read [docs/cloud-guest-upgrades.md](../docs/cloud-guest-upgrades.md): the daemon must start with the existing argv, adopt hosts of every build still running, keep hosts alive on SIGTERM, and open every older schema.
