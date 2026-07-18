# Rust Binding Style

The published client is synchronous and dependency-light.

Requirements:

- Generate typed request and response structs with Serde.
- Use snake_case public methods and kebab-case wire names.
- Return `Result<T, CmuxError>`.
- Provide non-exhaustive event enums with an unknown-event fallback.
- Preserve command, transport, timeout, decode, and protocol-version error categories.
- Expose blocking streams first; async adapters can come later.
- Resolve default sockets from `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; ignore empty values and apply the Darwin 103-byte fallback from the transport spec.
- Decode protocol-v8 UUIDs into a strict lowercase `Uuid` value type.
- Keep `topology_revision` and `canonical_topology_revision` separate; only the canonical field constructs `TopologyCursor`.
- Return `TopologySubscribeOutcome`, then yield `TopologyStreamEvent` while daemon, session, and adjacent revisions match.
- Convert fence failures and every daemon recovery reason into `ResnapshotRequired`, close the stream, and never yield a later delta.
