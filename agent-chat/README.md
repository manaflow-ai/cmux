# cmux-agent-ui

MVP of the "UI mode" for cmux: a web chat surface (initial composer + chat view) rendered in cmux's existing browser surface, backed by any coding agent CLI. No Swift changes; the app side is just `cmux browser open http://127.0.0.1:7739`.

## Run

Three entrypoints, all landing on the same server:

- **CLI** (`cmux-chat`, symlinked into `~/.local/bin`): `cmux-chat` opens a composer as a new workspace tab; `cmux-chat -p codex fix the tests` starts the chat immediately; `--split` opens in the current workspace instead; `--no-open` prints the URL. It auto-starts the server if needed.
- **Command palette**: `Cmd+Shift+P` → "New Agent Chat". Wired via `~/.config/cmux/cmux.json` (`actions.agent-chat` → `workspaceCommand` "Agent Chat" with a browser-surface layout), cmux's designed extension point, so no app build. When this productizes it becomes a built-in palette command in the cmux repo.
- **Server** runs under launchd (`~/Library/LaunchAgents/com.cmux.agent-ui.plist`, KeepAlive) on http://127.0.0.1:7739. Remove with `launchctl bootout gui/501/com.cmux.agent-ui && rm ~/Library/LaunchAgents/com.cmux.agent-ui.plist`. Manual run: `bun server.ts`.

One page = one session: `/` is the composer, `/s/<id>` a chat. There is deliberately no in-page session list or header; each chat is its own cmux workspace tab (page title = first prompt), so cmux's sidebar is the session list.

## Theming

The server resolves the terminal's colors from `~/.config/ghostty/config` (theme file from `~/.config/ghostty/themes` or the cmux/Ghostty app bundle, explicit `background`/`foreground` overrides, `background-opacity`, blur) and injects them as CSS variables at serve time, so the page paints with the terminal background on first frame. The whole palette derives from bg/fg via `color-mix`, so light and dark themes both work; `/api/theme` exposes the resolved values. Splits opened by `cmux-chat --split` use `browser.open_split` with `transparent_background: true` plus `?transparent=1`, so the body is `rgba(bg, background-opacity)` and Ghostty transparency/blur shows through. Workspace-tab chats (palette, default CLI) are solid theme-bg because cmux workspace layout definitions don't carry a transparency flag yet; adding `transparent` to `CmuxSurfaceDefinition` in cmux would close that gap. Theme changes apply on page reload.

Smoke test every provider end to end (spawns real agents):

```bash
bun test/e2e.ts               # or: bun test/e2e.ts codex pi
```

## Architecture

```
browser surface (public/index.html)
        │ WebSocket (common event schema)
server.ts (Bun): session manager, replayable event log per session
        │
adapters/: normalize each provider into AgentEvent
  claude.ts   persistent `claude -p --input/output-format stream-json`
  codex.ts    shared `codex app-server` (JSON-RPC), one thread per session
  pi.ts       persistent `pi --mode rpc`
  acp.ts      generic ACP (JSON-RPC/NDJSON over stdio) client → opencode, gemini, …
```

The UI only knows `AgentEvent` (types.ts): `user`, `delta`, `assistant`, `thinking`, `tool-start/end`, `status`, `done`, `error`, `meta`. Sessions live in server memory with a full event log, so any client (reload, second browser, future native surface) can subscribe and replay.

## How this covers every agent provider

Two adapter families are enough, and family 2 is a single implementation:

1. **Native stream-JSON/JSON-RPC CLIs.** Claude Code (`--output-format stream-json`), Codex (`app-server`, the JSON-RPC server its IDE extension uses), pi (`--mode rpc`), cursor-agent and amp have the same shape. Each needs a ~100-line adapter because event names differ, but they all reduce to the same event set: text deltas, tool start/end, turn done. Use a native adapter when the native protocol carries things ACP doesn't yet (Claude permission modes/hooks, Codex thread/turn model and approvals).
2. **ACP (Agent Client Protocol, agentclientprotocol.com).** One generic client (`adapters/acp.ts`) speaks initialize → session/new → session/prompt, renders `session/update` notifications, and answers reverse requests (`session/request_permission`). That single file already runs opencode (`opencode acp`) and gemini (`gemini --acp`), and gets claude (`@zed-industries/claude-code-acp`), goose, marimo, and future agents for free. ACP is the long-term contract: it's the protocol Zed drove, adapters keep appearing, and it standardizes exactly the hard parts (permissions, fs proxying, tool call lifecycle, plans).

Capability differences are absorbed by the schema, not the UI:

| provider  | transport            | streaming | tools visible | multi-turn                 | permissions |
|-----------|----------------------|-----------|---------------|----------------------------|-------------|
| claude    | persistent stdio     | deltas    | yes           | persistent proc            | permission-mode / allowedTools |
| codex     | app-server JSON-RPC  | deltas    | yes           | thread per session         | approval requests |
| opencode  | ACP persistent stdio | deltas    | yes           | ACP session                | request_permission round-trip |
| gemini    | ACP persistent stdio | deltas    | yes           | ACP session                | `--yolo` or request_permission |
| pi        | persistent stdio     | deltas    | yes           | persistent proc            | none (always executes) |

Adding a provider is either one registry entry (ACP-speaking: id + cmd) or one small adapter file (bespoke stream-JSON). Nothing in the UI changes.

### Known env quirks (this machine)

- gemini: Google now blocks Gemini Code Assist for individuals (`IneligibleTierError`, migrate-to-Antigravity). ACP handshake works; auth fails upstream. Registry keeps it; it errors fast in the UI.
- claude: TTFT is ~1-2 min on this machine when an `ANTHROPIC_API_KEY`/proxy auth source is active; the UI streams fine once tokens start.

## What the real cmux feature needs beyond this MVP

- A native `AgentChatSurface` (or a pinned browser surface type) with the composer as the new-workspace view; the server becomes a cmux-owned daemon keyed by workspace, sessions persisted to disk (each provider already has resume: claude `--resume`, codex thread ids, ACP `session/load`).
- Permission requests routed to native cmux dialogs/notifications instead of the auto-approve toggle; ACP already models this, and claude gets it via `--permission-prompt-tool` or the ACP adapter.
- Attach chat sessions to the workspace's terminal/worktree (cwd = worktree, show diffs via `cmux-diff`), and a "open in terminal" escape hatch that resumes the same session in the provider's TUI (`claude --resume <id>`, `codex resume <thread>`).
- Provider registry in `~/.config/cmux/agents.json` so users can add any ACP/stream-JSON agent without code.
