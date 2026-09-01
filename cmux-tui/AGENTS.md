# cmux-tui agent instructions

Do not run `cargo`, `rustc`, or Zig on Lawrence's Mac. Do not use a local build as a fallback. Commit and push the exact branch head, then use the hosted entry point from the repository root:

```bash
./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
./scripts/verify-cmux-tui-hosted.sh --full
```

Use `--filter` during focused development. It accepts one Rust test-name substring and verifies that the filter selects at least one test on hosted Linux and macOS. The reserved `chatmux_relay` (or `chatmux-relay`) selector runs the complete `chatmux-relay` package because Cargo test names do not include package names. Use `--full` for the merge gate. Full mode runs the complete Linux and macOS suites, package builds, and a Windows-hosted binary execution check.

The script rejects dirty or unpushed work, verifies the exact commit in every hosted job, waits for completion, prints failed logs, and downloads the macOS arm64 binary to `cmux-tui/target/hosted/<commit>/cmux-tui`. Running that downloaded binary on the Mac is allowed.

`rust-toolchain.toml` is the single Rust toolchain source for hosted TUI tests, package builds, and live conformance. Change that file instead of adding a workflow-specific Rust version.
