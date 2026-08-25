# TypeScript Binding Style

Generate one transport-independent TypeScript package with separate Node and
browser entry points.

Requirements:

- Use promises for command methods.
- Use discriminated unions for event payloads keyed by `event`.
- Preserve exact wire field names in serialized JSON.
- Expose idiomatic camelCase methods that map 1:1 to kebab-case command names.
- Preserve command errors with the server message.
- Preserve exact `uint64` values as `bigint`.
- Keep browser entry points free of Node imports.
- Use Node Unix socket APIs and injected browser/WebSocket transports.
- Provide async iterables for subscribe and attach streams.
- Bound pending responses, unread events, and retained attach payloads.
- Keep command deadlines separate from optional stream-idle deadlines.
- Support `AbortSignal` without leaking listeners or changing server execution claims.
- Preserve unknown events through a distinct, soundly narrowed fallback.
- Do not generate active methods for proposed commands before their protocol version lands.

Generated wire code and hand-written transports must remain separate. The
package has no runtime dependencies.
