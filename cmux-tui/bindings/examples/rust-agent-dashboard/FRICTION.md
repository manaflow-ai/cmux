# Rust SDK consumer friction

1. Rust resource snapshots currently expose only typed IDs, ancestry, name,
   revision, and a forward-compatible `extra` map. The dashboard deliberately
   avoids that map, so it learns agent state by issuing one typed `agent.list`
   filter per `AgentState`.
2. `Agent` lacks the `id()` convenience method implemented by most other
   resource handles. The consumer matches its public `Selector` to recover the
   ID returned by `agent.list`.
3. Filtered agents do not expose a typed terminal ID. Blocked notifications
   therefore target the session rather than the agent terminal.
4. Reconnect remains application-owned. A failed request recreates `Client`,
   reselects the current session, and refreshes all dashboard resources.
5. `session.events()` provides typed event categories, but resource upsert
   values remain `Document`. This consumer polls typed list/filter operations
   instead of decoding generic delta documents.

The consumer imports only the `cmux` crate root. It uses no `cmux::raw`,
protocol command names, private modules, generic request method, or
`Document::deserialize`.
