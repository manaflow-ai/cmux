# cmux computer use (MCP server)

An agent-agnostic replica of **Codex Computer Use** as a cmux capability: any MCP
agent cmux launches (Claude, Codex, …) can drive the local Mac through the same
AX-tree-grounded screenshot perception and element-index actions Codex Computer
Use itself uses.

There is no custom automation engine here. `cmux-computer-use-mcp.mjs` is a
dependency-free node script that spawns the **standard** `codex app-server`
(stdio transport) from the user's Codex install and proxies tool calls to its
bundled `computer-use` MCP server (`initialize` → `thread/start` →
`mcpServer/tool/call`). Perception results come back exactly as Codex Computer
Use sees them: the accessibility tree as text plus the screenshot as MCP image
content, so a vision agent grounds its clicks in real element indices instead of
guessing pixels.

## Requirements

Exactly what Codex Computer Use requires — nothing else:

- A trusted Codex install that bundles the computer-use plugin:
  `/Applications/Codex.app`, or a current Codex CLI path set explicitly through
  `CMUX_CU_CODEX`.
- A logged-in Codex: `codex login` must have produced `~/.codex/auth.json`.
  The codex app-server fails tool calls when auth is missing or revoked.
- macOS permissions for the Codex Computer Use helper app (Accessibility /
  Screen Recording). Codex prompts for these on first use; they are stored under
  `~/.codex/computer-use/`.

## Auto-attach in cmux

cmux attaches this server to `claude` launches automatically (the
`cmux-claude-wrapper` injects `--mcp-config` pointing at the bundled copy of
this script). Injection is skipped when any of these hold:

- `CMUX_COMPUTER_USE_MCP_DISABLED=1` (explicit kill switch),
- no trusted absolute `node` is found on PATH,
- no trusted auto-attach codex binary is found (`CMUX_CU_CODEX` or Codex.app) or
  `~/.codex/auth.json` is missing — without the Codex machinery the tools could
  never work,
- the invocation passes `--strict-mcp-config` (explicit MCP isolation, e.g.
  cmux's own headless summarizers).

Codex agents need nothing: recent codex versions ship computer use natively
(`codex features list` → `computer_use  stable  true`), so cmux injects nothing
into codex launches.

## Manual setup (any MCP agent)

Claude Code:

```bash
CMUX_CU_CODEX=/absolute/path/to/codex \
  claude mcp add cmux-computer-use -- node /path/to/cmux-computer-use-mcp.mjs
```

Codex (only needed for older versions without native computer use), in
`~/.codex/config.toml`:

```toml
[mcp_servers.cmux_computer_use]
command = "node"
args = ["/path/to/cmux-computer-use-mcp.mjs"]
[mcp_servers.cmux_computer_use.env]
CMUX_CU_CODEX = "/absolute/path/to/codex"
```

Inside the cmux app bundle the script is at
`cmux.app/Contents/Resources/cmux-computer-use-mcp.mjs`; in this repo it is
`Resources/computer-use-mcp/cmux-computer-use-mcp.mjs`.

## Per-app approvals

Codex Computer Use asks the human before controlling each app. This server
keeps that: the engine's approval elicitation ("Allow Codex to use
Calculator?") is forwarded to the MCP client as a standard MCP
`elicitation/create`, so in an interactive Claude session the user sees a
native Accept/Decline prompt. Clients that never declared elicitation support
get a fail-closed decline, and headless runs (`claude -p`) cancel the prompt —
unattended automation must consciously opt in with `CMUX_CU_AUTO_APPROVE=1`.
Approvals live in the engine per app for the lifetime of the MCP session.

The tools that do not go through the engine sit behind the same boundary:
full-desktop `computer_screenshot`, `computer_windows`, and `computer_open`
each ask for their own approval ("capture the entire desktop", "list every
on-screen window", "launch or focus <app>") before touching
`screencapture`/CGWindowList/`open -a`, cached per capability for the session.

## Config (env)

- `CMUX_CU_CODEX` — path to the codex binary. When set it decides alone — no
  fallback. When unset, the server and cmux-claude-wrapper only probe
  `/Applications/Codex.app/Contents/Resources/codex`; they do not execute PATH
  candidates during ordinary agent startup. The wrapper also pins a trusted absolute `node`
  command instead of relying on the MCP client's runtime PATH. The wrapper pins
  its trusted Codex result into the injected config as `CMUX_CU_CODEX`, so the
  availability gate and the spawned engine always agree on one binary.
- `CMUX_CU_TIMEOUT_MS` — per-command timeout (default `180000`).
- `CMUX_CU_MAX_TREE` — max AX-tree characters returned by `computer_state`
  (default `60000`).
- `CMUX_CU_AUTO_APPROVE=1` — pre-approve every computer-use approval: the
  engine's per-app control elicitations and the local desktop-capture /
  window-list / app-launch gates (headless automation only; see "Per-app
  approvals").

## Tools (12)

- `computer_target` — report the machine + engine being driven.
- `computer_apps` — list controllable apps.
- `computer_open` — launch/focus an app (`open -a`).
- `computer_state` — PRIMARY perception: AX tree + screenshot for an app.
  Element indices in the tree are what the action tools take, and they are
  valid only for that snapshot.
- `computer_screenshot` — one app's window, or the full desktop (no `app`).
- `computer_click` — by element index (preferred) or x/y screen points.
- `computer_type` — type into the focused field.
- `computer_key` — key/chord, e.g. `Return`, `cmd+l`.
- `computer_scroll` — scroll an element by direction/pages.
- `computer_drag` — drag between screen points.
- `computer_action` — invoke a named accessibility action on an element.
- `computer_windows` — CGWindowList dump (JSON), optional match filter.

## Smoke test

```bash
cd Resources/computer-use-mcp
npm install            # dev-only: the official MCP SDK client for the smoke script
node scripts/smoke.mjs                                # initialize + tools/list + computer_target
node scripts/smoke.mjs computer_state '{"app":"Calculator"}'   # real engine: AX tree + [image ...]
```

The second command exercises the full stack (spawn app-server → thread →
`get_app_state`) and must print an accessibility tree plus an `[image ...]`
content item. The server itself has no runtime dependencies; `npm install` is
only for the smoke client.

## Parity evidence

`demo/` holds before/after captures from a real parity run (2026-07-01): a
headless Claude (fable-5) drove macOS Calculator exclusively through this MCP —
`computer_state` → clicked All Clear + digit buttons **by AX element index** →
`computer_type "+69"` → `computer_key Return` → fresh `computer_state` →
result `136`, with the AX tree and screenshot agreeing. The same flow
(All Clear → `55+45` → Return → `100`) was re-run against this vendored,
direct-app-server implementation before it landed.

## Limitations

- Requires codex auth: tool calls fail while `~/.codex/auth.json` is missing,
  expired, or revoked. That is how Codex Computer Use works; log in with
  `codex login`.
- Cold start: the first perception call after the app-server starts can fail
  if the computer-use service dies while warming up. Read-only calls retry
  once (the app-server queues the retry until the respawned service reports
  ready — no wall-clock waits); input actions are never auto-retried.
- Element indices are snapshot-specific. Element-index actions fail closed
  when the current session has no `computer_state` snapshot for the app (for
  example after an app-server restart): re-run `computer_state` and use the
  fresh indices.
- Full-desktop `computer_screenshot` uses `screencapture`, which needs Screen
  Recording permission for the hosting terminal app. Per-app capture goes
  through the engine's helper and does not.
- `computer_windows` compiles a tiny Swift snippet (`swift -`) because the JXA
  ObjC bridge crashes on `CGWindowListCopyWindowInfo` on recent macOS; it
  needs the Xcode Command Line Tools.
