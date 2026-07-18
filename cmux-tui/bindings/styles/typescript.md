# TypeScript Binding Style

Generate a Node.js TypeScript package under `cmux-tui/bindings/typescript/`.

Requirements:

- Use promises for command methods.
- Use discriminated unions for event payloads keyed by `event`.
- Preserve exact wire field names in serialized JSON.
- Expose idiomatic camelCase methods that map 1:1 to kebab-case command names.
- Preserve command errors with the server message.
- Use Node Unix socket APIs for protocol v5.
- Resolve default sockets from `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; ignore empty values and apply the Darwin 103-byte fallback from the transport spec.
- Provide async iterables for subscribe and attach streams.
- Export branded `UUID`, canonical topology models, `TopologyCursor`, and both topology outcome unions from browser and Node entry points.
- Gate topology methods on protocol 8, all three named capabilities, and the canonical identify cursor.
- Validate daemon, session, and adjacent revisions before advancing the subscription cursor.
- Return discriminated `resnapshot-required` outcomes for daemon recovery, fence failures, and local topology replay-buffer overflow.
- Include consumer-side implemented `moveTab` and `moveWorkspace`.
- Do not generate active methods for proposed commands unless they are version-gated and clearly marked.

The package should be generated source-first and leave build tooling minimal.
