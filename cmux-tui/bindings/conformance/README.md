# Public resource SDK conformance

This suite drives the handwritten Python, TypeScript, Rust, Go, Java, C++,
and Zig SDK roots through one `cmux.protocol/1` contract. The fake server
checks exact Unix JSONL requests and exercises reads, mutation replay,
revision and ambiguity errors, indeterminate external effects, typed unknown
stream items, cancellation ordering, decimal strings, redaction, and
stream-local message and byte overflow.

Run all installed toolchains from the repository root:

```sh
python3 cmux-tui/bindings/conformance/runner.py \
  --require python,typescript,rust,go,java,cpp,zig
```

Use `--no-build` to reuse adapter outputs. Pass
`--cmux-tui-bin cmux-tui/target/debug/cmux-tui` to run each adapter against
that exact executable in an isolated durable session. The live suite creates
duplicate names, proves ambiguous selection cannot mutate either candidate,
restarts the server against the same state root, verifies stable IDs and
names, then closes and verifies every fixture. TypeScript runs the same
lifecycle over Unix and authenticated WebSocket transports.

The Zig adapter targets Zig 0.15.2. Set `CMUX_ZIG` when that compiler is not
the `zig` on `PATH`.

Generated protocol-10 compatibility tests are intentionally separate:

```sh
python3 cmux-tui/bindings/conformance/raw/runner.py \
  --require python,typescript,rust,go,java,cpp,zig
```

The adapter process contract is in
[`adapter-protocol.md`](adapter-protocol.md).
