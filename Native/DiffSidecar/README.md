# Diff sidecar

`cmux-diff-sidecar` is the portable command boundary for the diff viewer. The macOS app sends one typed request over stdin/stdout when the branch picker needs backend work, then the sidecar exits. Diff HTML, modules, and patch files use the app-owned `cmux-diff-viewer://` allowlist, so opening a viewer creates no TCP listener or idle backend process. Rust still delegates cmux-specific Git semantics to hidden CLI commands while that behavior moves behind the portable boundary.

`src/protocol.rs` is the protocol source of truth. `scripts/generate-diff-sidecar-types.sh` generates `webviews/src/diff/generated/protocol.ts`; CI rejects stale generated types. React selects a `fetch`, `webSocket`, or `webKit` frontend transport from the payload. macOS uses WebKit reply messages backed by sidecar stdio. Future browser hosts can select Fetch or WebSocket without changing commands or result types. Patch bodies stay outside command replies and are served by each host's resource transport.

Rust is a required macOS build dependency. `scripts/setup.sh` verifies the toolchain using the same rustup and Homebrew paths available to Xcode build phases.

Run `scripts/benchmark-diff-viewer.sh` from the repository root. It measures Rust manifest decoding and patch reads, then exercises the real Pierre parser and streaming batcher with 2,000 files. CI enforces conservative p95 and throughput budgets to catch large regressions without treating shared-runner noise as a failure.
