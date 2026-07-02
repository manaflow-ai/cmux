# cmux computer use — design

Goal: replicate the functionality and effectiveness of **Codex Computer Use**, but as a
**cmux** capability that **any agent** (Claude, Codex, …) can use, driving a real Mac —
surfaced inside cmux like a terminal or browser pane.

## How Codex Computer Use actually works (what we're matching)

Codex Computer Use is not a special model we must rebuild. It is:

1. A **computer-use MCP server** bundled with every standard Codex install
   (`@openai/codex` npm package and Codex.app both ship it under
   `plugins/openai-bundled/plugins/computer-use/`), hosted by the Codex
   *app-server* and exposing perception + action primitives:
   - perception: `list_apps`, `get_app_state` (accessibility tree **+ screenshot**)
   - action: `click` (by AX element index or x/y), `type_text`, `press_key`,
     `scroll`, `drag`, `perform_secondary_action`
2. An **agent loop** that calls those primitives: `state → reason over
   screenshot+AX → act → state …`

The effectiveness comes from the **AX-tree-grounded screenshot perception** +
element-index actions (not raw pixel guessing). Nothing about the engine requires the
Codex *model* — it is "Codex-specific" today only because the `computer-use` MCP is wired
into the Codex app-server.

## The cmux version (this directory)

Make it agent-agnostic by lifting the same primitives into a **standalone MCP stdio
server** that any MCP client can attach to. `cmux-computer-use-mcp.mjs` is that server.
It talks **directly to the standard Codex machinery** — no third-party bridge, no cmux
infrastructure:

- spawn `codex app-server` (its default `stdio://` transport) from the user's own Codex
  install (`codex` on PATH, else Codex.app),
- speak its JSON-RPC protocol: `initialize` (with `experimentalApi`) → `initialized` →
  `thread/start` (one ephemeral thread per MCP session, so the engine's element-index
  table persists across calls exactly like a native Codex Computer Use session) →
  `mcpServer/tool/call` against the `computer-use` server,
- answer server→client requests the way a non-interactive client must
  (accept computer-use elicitations, decline command/file approvals),
- map results to MCP content: `computer_state` returns the AX tree as text **and the
  screenshot as MCP image content**, so a vision agent sees exactly what Codex Computer
  Use sees.

Because it reuses the engine unchanged, a Claude agent driving through this MCP gets the
same perception+action quality as Codex Computer Use — that is the whole point.

The server is dependency-free (plain node, newline-delimited JSON-RPC on both sides) so
the app bundles the single file and attaches it to agent launches with no install step.

## Auto-availability (phase 1 — this PR)

`Resources/bin/cmux-claude-wrapper` injects `--mcp-config` (pointing at the bundled
server) into `claude` session launches, gated only on the Codex machinery actually being
present (codex binary + `~/.codex/auth.json`, `node` on PATH, no `--strict-mcp-config`,
no `CMUX_COMPUTER_USE_MCP_DISABLED=1`). Codex agents already have computer use natively
(`computer_use` is a stable, default-on codex feature), so codex launches get nothing
injected. There is no Settings surface: like Codex Computer Use itself, it works when
the machinery is installed and logged in, and does not exist when it is not.

## Status

- [x] Agent-agnostic MCP server (12 tools, screenshot-as-image) — protocol-validated
      against the official MCP SDK client.
- [x] Proof: a **Claude** agent (fable-5) completed a GUI task on a real Mac through
      this MCP — Calculator driven purely by element-index clicks + typing; AX tree and
      screenshot agree on the result (`demo/`, 2026-07-01).
- [x] Direct codex app-server integration (no external bridge) — the parity flow
      (All Clear → `55+45` → Return → `100`) re-verified against this implementation.
- [x] Auto-availability at agent launch (this PR).
- [ ] `.computerUse` pane + human takeover (phase 2).

## Path into cmux proper (next phases)

1. **A `.computerUse` PanelType**: render the driven screen in a pane, with human
   takeover — human + agent on one desktop, the cmux signature.
2. **Recording**: capture agent-driven GUI sessions (cmux already values demo videos).
3. **Remote/cloud Macs**: point the same tool surface at a leased cloud Mac (lifecycle
   mirroring cmux's AgentHibernation pattern) instead of the local one.
