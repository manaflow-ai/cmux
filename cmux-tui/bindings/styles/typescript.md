# TypeScript Binding Style

Generate a Node.js TypeScript package under `cmux-tui/bindings/typescript/`.

Requirements:

- Use promises for command methods.
- Use discriminated unions for event payloads keyed by `event`.
- Preserve exact wire field names in serialized JSON.
- Expose idiomatic camelCase methods that map 1:1 to kebab-case command names.
- Preserve command errors with the server message.
- Use Node Unix socket APIs for protocol v5.
- Provide async iterables for subscribe and attach streams.
- Include consumer-side implemented `moveTab` and `moveWorkspace`.
- Do not generate active methods for proposed commands unless they are version-gated and clearly marked.

The package should be generated source-first and leave build tooling minimal.
