# Diff sidecar

`cmux-diff-sidecar` is the portable backend boundary for the diff viewer. It owns the loopback HTTP server, capability-token resource allowlist, remote patch streaming, typed command protocol, and Fetch/WebSocket endpoints. Swift starts the bundled process and still handles cmux-specific Git semantics through hidden CLI commands, which preserves existing diff behavior while the portable boundary moves to Rust.

`src/protocol.rs` is the protocol source of truth. `scripts/generate-diff-sidecar-types.sh` generates `webviews/src/diff/generated/protocol.ts`; CI rejects stale generated types. The React client selects a `fetch`, `webSocket`, or `webKit` command transport from the payload. Patch bodies remain streamable resources, so HTTP and custom WebKit URL schemes do not require buffering a diff into a message reply.

Run `scripts/benchmark-diff-viewer.sh` from the repository root. It measures Rust manifest decoding and patch reads, then exercises the real Pierre parser and streaming batcher with 2,000 files. CI enforces conservative p95 and throughput budgets to catch large regressions without treating shared-runner noise as a failure.
