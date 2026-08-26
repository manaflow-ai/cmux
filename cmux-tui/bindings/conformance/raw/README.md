# Raw protocol-12 SDK conformance

This suite exercises generated protocol-12 APIs through the explicit
`raw` package in Python, TypeScript, Rust, Go, Java, C++, and Zig. The public
resource API conformance suite lives one directory above this file.
Metadata coverage retains the protocol-10 and protocol-11 baselines from
commits `34741cdc96` and `236f57ff60`, and requires protocol-12 metadata to
remain a superset of both.

The deterministic fake server covers partial frames, exact `uint64` limits,
oversized responses, invalid UTF-8, timeouts, events before acknowledgement,
unknown events, terminal overflow, closing a pending read, five stream modes,
four successful authority boundaries, and a default provider-authority denial
that proves zero bytes reach the socket. Handwritten fixtures independently
verify missing, explicit null, and typed values. They cover an
optional-nullable request, required-nullable responses and events, and
optional non-null responses and events. Exact request matching rejects
accidental fields.
Three live checks start an isolated headless `cmux-tui` server, call
`identify` and `ping`, then create a workspace and terminal, send and read a
marker, verify ordered delta events, rename the workspace, close it, and
confirm it disappeared.

The full seven-language run executes 266 checks: 34 fake cases, one metadata
audit, and three live cases per language.

From the repository root:

```sh
python3 cmux-tui/bindings/conformance/raw/runner.py \
  --require python,typescript,rust,go,java,cpp,zig
```

Use a prebuilt server with `--cmux-tui-bin cmux-tui/target/debug/cmux-tui`.
Use `--fake-only` while changing an adapter. `--no-build` reuses binaries in
`conformance/.build`. `--no-codegen-check` is only for diagnosing stale
generated SDK output.

Set `CMUX_ZIG` when the supported Zig 0.15.2 executable is not named `zig`.
On macOS, a standalone Zig distribution may also need `DEVELOPER_DIR` and
`SDKROOT`.

Adapters consume normal package boundaries where practical: TypeScript uses
compiled `dist` exports, Java and C++ link compiled package outputs, and
Rust, Go, and Zig resolve their public package modules as downstream
consumers. Python imports its zero-dependency package tree directly so the
suite does not mutate the active Python environment.

The adapter process protocol is documented in
[`adapter-protocol.md`](adapter-protocol.md). All build output stays under the
ignored `conformance/.build` directory.
