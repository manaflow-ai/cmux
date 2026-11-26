# Agent dot signatures: a small dot glyph made from each agent's session id, on sidebar rows and the running line (`appearance.agentSignature`, off by default; Leo 2026-11-19)

- Section: Workspaces
- Mac sends: acpmux `session/signature {sessionIds}` (a pure function of the id; read-only paired devices may call it)
- Phone: —
- State: missing
- Notes: The phone can ask its Mac's acpmux the same request and draw the same dots on its agent list and chat running line; a follow-up. The setting stays settable over `cmux settings` like any setting.
