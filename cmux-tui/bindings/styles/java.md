# Java Binding Style

The published Java 17 client is built with `javac` and has no external runtime dependency.

Requirements:

- Provide a builder for client configuration.
- Use immutable result value objects.
- Use builders for requests with multiple optional parameters.
- Separate command, transport, decode, timeout, and protocol mismatch errors.
- Provide a synchronous stream interface first; callbacks or Flow publishers may be added later.
- Resolve default sockets from `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; ignore empty values and apply the Darwin 103-byte fallback from the transport spec.
- Use immutable records and `java.util.UUID` for protocol-v8 canonical topology.
- Keep legacy and canonical revisions distinct; `IdentifyResult.topologyCursor()` uses the canonical field.
- Represent subscribe results with the sealed `TopologySubscribeOutcome` interface and stream results with `TopologyStreamEvent`.
- Close a subscription before returning a resnapshot requirement caused by authority mismatch or a revision gap.
