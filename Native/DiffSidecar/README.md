# Diff sidecar

`cmux-diff-sidecar` is the portable command boundary for the diff viewer. The macOS app sends one typed request over stdin/stdout when the branch picker needs backend work, then the sidecar exits. Diff HTML, modules, and patch files use the app-owned `cmux-diff-viewer://` allowlist, so opening a viewer creates no TCP listener or idle backend process. Rust delegates cmux-specific Git semantics to hidden CLI commands while that behavior moves behind the portable boundary.

The bundled production binary has no default Cargo features. It includes only `rpc` and `handshake`; HTTP, WebSocket, remote TLS streaming, file watching, and benchmarks are opt-in development code. Run HTTP integration tests with `--all-features`. Run benchmarks through `scripts/benchmark-diff-viewer.sh`, which enables only the `benchmark` feature.

`src/protocol.rs` is the protocol source of truth. `scripts/generate-diff-sidecar-types.sh` generates `webviews/src/diff/generated/protocol.ts`; CI rejects stale generated types. React selects a `fetch`, `webSocket`, or `webKit` frontend transport from the payload. macOS uses WebKit reply messages backed by sidecar stdio. Future browser hosts can select Fetch or WebSocket without changing commands or result types. Patch bodies stay outside command replies and are served by each host's resource transport.

The stdio transport accepts one request of at most 1 MiB and requires EOF within 10 seconds. Timeout, oversized, and malformed envelopes return a typed failure with ID `__cmux_untrusted_request__`, because no caller-supplied request ID is trusted until the complete envelope parses.

Rust is a required macOS build dependency. `rust-toolchain.toml` pins Rust 1.88.0, including both Apple targets. Every setup, CI, generation, benchmark, and Xcode command runs Cargo through that exact rustup toolchain with `--locked`. Release builds use size optimization, fat LTO, one codegen unit, symbol stripping, isolated per-architecture target directories, and `MACOSX_DEPLOYMENT_TARGET=14.0`.

`scripts/build-diff-sidecar.sh` creates the requested slices and combines them with `lipo`. `scripts/verify-diff-sidecar-artifact.sh` executes the handshake and rejects missing slices, non-system dynamic dependencies, a deployment target other than macOS 14.0, linkable symbols, invalid executable permissions, or a binary larger than 5 MiB. Release signing runs the same check again and requires a valid code signature.

Run `scripts/benchmark-diff-viewer.sh` from the repository root. It measures Rust manifest decoding and patch reads, then exercises the real Pierre parser and streaming batcher with 2,000 files. CI enforces conservative p95 and throughput budgets to catch large regressions without treating shared-runner noise as a failure.
