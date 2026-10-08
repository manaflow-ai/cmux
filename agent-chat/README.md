# cmux-agent-ui

MVP of the "UI mode" for cmux: a web chat surface (initial composer + chat view) rendered in cmux's existing browser surface, backed by any coding agent CLI. In production cmux launches the sidecar on a discovered loopback port and opens the unguessable token-prefixed URL it reports.

## Run

Three entrypoints, all landing on the same server:

- **CLI** (`cmux-chat`, symlinked into `~/.local/bin`): `cmux-chat` opens a composer as a new workspace tab; `cmux-chat -p codex fix the tests` starts the chat immediately; `--split` opens in the current workspace instead; `--no-open` prints the URL. It auto-starts the server if needed.
- **Command palette**: `Cmd+Shift+P` → "New Agent Chat". Wired via `~/.config/cmux/cmux.json` (`actions.agent-chat` running `cmux-chat`), cmux's designed extension point, so no app build. A static browser-surface URL no longer works: every route is under the server's per-launch token, which `cmux-chat` reads. When this productizes it becomes a built-in palette command in the cmux repo.
- **Server** runs as a cmux sidecar. Manual dev run: `bun server.ts` (defaults to `http://127.0.0.1:7739`). Without a launcher token the server makes a per-launch token and writes it to an owner-only file (`CMUX_AGENT_CHAT_TOKEN_FILE`, default `~/.cmux/agent-chat/token-<port>`); `cmux-chat` reads it. Production launchers set `CMUX_AGENT_CHAT_PORT=0`, `CMUX_AGENT_CHAT_TOKEN=<unguessable>`, and `CMUX_AGENT_CHAT_STATE_FILE=<path>`; after bind the server atomically writes `{"port":..., "pid":..., "protocolVersion":1}` so cmux can open `http://127.0.0.1:<port>/<token>/`.

One page = one session: `/` is the composer, `/s/<id>` a chat. Every HTTP route, static asset, API route, and WebSocket upgrade except `/healthz` must be under `/<token>/...` (compared in constant time); missing or wrong tokens return 404. Every request, `/healthz` included, needs a `Host` that names this server (a loopback name with its port) and, when it has an `Origin`, this server's own origin; anything else gets 403. There is deliberately no in-page session list or header; each chat is its own cmux workspace tab (page title = first prompt), so cmux's sidebar is the session list.

## Terminal chat view

`/terminal/<surface-id>` shows a Claude Code or Codex session that is already running in a cmux terminal as a chat, without starting another agent. The sidecar looks the surface up in the hook session stores (`~/.cmuxterm/claude-hook-sessions.json`, `~/.cmuxterm/codex-hook-sessions.json`), tails the agent's own transcript (Claude `projects/<slug>/<session>.jsonl`, Codex `sessions/YYYY/MM/DD/rollout-*-<session>.jsonl`), and normalizes it into `AgentEvent`s with `adapters/transcript.ts`, so the regular chat renderer draws it. The page lives at `/s/t-<agent session id>`, which re-resolves after a sidecar restart; a view with no open page stops tailing after five minutes.

The terminal stays the source of truth. The composer types the prompt into the terminal's agent with `mobile.chat.send` (bracketed paste and submit, the delivery the iOS chat uses), and Stop or Esc sends `mobile.chat.interrupt`; both go over the cmux control socket through `cmux rpc` (`cmux-rpc.ts`, using the `CMUX_BUNDLED_CLI_PATH` and `CMUX_SOCKET_PATH` the app passes to the sidecar). The prompt shows immediately and is replaced by the transcript's own copy when it lands. Permission prompts, questions, and pickers stay in the terminal: when the hook store says the agent needs input, the view shows the request with an "Answer in terminal" button that focuses the terminal pane. Open the view with "Open terminal as chat" in the command palette (Agent Chat UI flag) or `cmux-chat --terminal --surface <surface-id>` from a shell.

## Model catalog

The sidecar fetches the model catalog from `https://cmux.dev/api/agent-models` (`CMUX_AGENT_MODELS_URL` overrides it for development), revalidates it with ETags after a one-hour TTL, and caches the last-good response at `~/.cache/cmux-agent-chat/models.json` for offline startup. Refreshes happen in the background; changed catalogs are pushed to open pages so model pickers update without reloading.

Remote entries define the offered model order, labels, descriptions, defaults, context metadata, fast-mode support, and Claude minimum-version gates. Models reported only by the installed binary are appended. The built-in Claude and Gemini lists are used only until a remote payload has been fetched or loaded from disk. Model IDs are passed to provider CLIs verbatim, including remote-only IDs, so newly released models work without a sidecar update.

## Theming

The server resolves the terminal's colors from `~/.config/ghostty/config` (theme file from `~/.config/ghostty/themes` or the cmux/Ghostty app bundle, explicit `background`/`foreground` overrides, `palette = N=#rrggbb` ANSI colors, `selection-background`, `cursor-color`, `background-opacity`, blur) and injects them as CSS variables at serve time, so the page paints with the terminal background on first frame. Syntax highlighting maps token colors to the injected Ghostty ANSI palette (`--ansi-*`), so code colors track the active terminal theme without rebuilding the client bundle. `/api/theme` exposes the resolved values. Splits opened by `cmux-chat --split` use `browser.open_split` with `transparent_background: true` plus `?transparent=1`, so the body is `rgba(bg, background-opacity)` and Ghostty transparency/blur shows through. Workspace-tab chats (palette, default CLI) are solid theme-bg because cmux workspace layout definitions don't carry a transparency flag yet; adding `transparent` to `CmuxSurfaceDefinition` in cmux would close that gap. Theme changes apply live (the server watches the config and cmux pushes its resolved theme on reload/appearance changes). The accent color is picked hue-aware from the palette (blue/cyan/violet candidates first); set `agent-chat-accent = #rrggbb` in the ghostty config to override it explicitly.

Agent-chat also reads optional font settings from `~/.config/cmux/cmux.json`:

```json
{
  "agentChat": {
    "fonts": {
      "sansFamily": "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif",
      "baseSize": 14,
      "monoFamily": "Berkeley Mono",
      "codeSize": 12.5,
      "codeLineHeight": 1.5
    }
  }
}
```

Defaults: body text uses the system sans stack at `14px`; code uses Ghostty's `font-family` and `font-size` when resolvable, otherwise the built-in monospace stack at `12.5px`; code line-height defaults to `1.5`.

Smoke test every provider end to end (spawns real agents):

```bash
bun test/e2e.ts               # or: bun test/e2e.ts codex pi
```

## Architecture

The frontend is a small React app built with Bun and styled to match the
terminal. Dropdowns and controls use `@base-ui-components/react` (Base UI),
the same component library the cmux web app uses: `Select` for the provider
picker and `Popover` for the working-directory editor and overflow menus.
Base UI ships unstyled, so every part is themed with the resolved Ghostty
colors. The server bundles `src/main.tsx` with `Bun.build` on startup and
serves it as `/app.js`; the HTML shell injects the theme CSS variables and
loads `app.css` relative to the current sidecar prefix.

```
browser surface (React app: src/*.tsx + Base UI)
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

1. **Native stream-JSON/JSON-RPC CLIs.** Claude Code (`--output-format stream-json`), Codex (`app-server`, the JSON-RPC server its IDE extension uses), pi (`--mode rpc`), and Amp ([`-x`/`--execute`, `--stream-json`, and `--stream-json-input`](https://ampcode.com/docs/cli/streaming-json)) have the same shape. Each needs a ~100-line adapter because event names differ, but they all reduce to the same event set: text deltas, tool start/end, turn done. Use a native adapter when the native protocol carries things ACP doesn't yet (Claude permission modes/hooks, Codex thread/turn model and approvals).
2. **ACP (Agent Client Protocol, agentclientprotocol.com).** One generic client (`adapters/acp.ts`) speaks initialize → session/new → session/prompt, renders `session/update` notifications, and answers reverse requests (`session/request_permission`). That single file already runs opencode (`opencode acp`), gemini (`gemini --experimental-acp`), goose (`goose acp`), and Cursor Agent (`cursor-agent acp`), and gets claude (`@zed-industries/claude-code-acp`), marimo, and future agents for free. ACP is the long-term contract: it's the protocol Zed drove, adapters keep appearing, and it standardizes exactly the hard parts (permissions, fs proxying, tool call lifecycle, plans).

Amp has no first-party ACP subcommand, only third-party bridges such as [amp-acp](https://github.com/tao12345666333/amp-acp).

Capability differences are absorbed by the schema, not the UI:

| provider  | transport            | streaming | tools visible | multi-turn                 | permissions |
|-----------|----------------------|-----------|---------------|----------------------------|-------------|
| claude    | persistent stdio     | deltas    | yes           | persistent proc            | permission mode |
| codex     | app-server JSON-RPC  | deltas    | yes           | thread per session         | approvals + sandbox options |
| opencode  | ACP persistent stdio | deltas    | yes           | ACP session                | auto-approve toggle for request_permission |
| goose     | ACP persistent stdio | deltas    | yes           | ACP session                | auto-approve toggle for request_permission |
| gemini    | ACP persistent stdio | deltas    | yes           | ACP session                | auto-approve toggle (`--yolo` at start) |
| cursor-agent | ACP persistent stdio | deltas    | yes           | ACP session                | auto-approve toggle for request_permission |
| pi        | persistent stdio     | deltas    | yes           | persistent proc            | none (always executes) |

Cursor Agent has two ACP capability gaps: it advertises blocking `cursor/ask_question` and `cursor/create_plan` requests, which this adapter answers with JSON-RPC `-32601` instead of prompting; it also advertises `cursor_login`, but the adapter does not call `authenticate`, so an unauthenticated `session/new` failure has no login hint.

Runtime options are declared by adapters as `SessionOption[]` and replayed as
`options` events. React renders the schema generically; provider-specific logic
stays in adapters.

| provider | option | mechanism |
|----------|--------|-----------|
| claude | model | `control_request` `list_models` / `set_model`; `default` omits model to reset |
| claude | mode | `set_permission_mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`, `dontAsk`, `auto`) |
| claude | thinking | `set_max_thinking_tokens` (`0`, `4096`, `16384`, `32768`) |
| claude | effort, fast | `apply_flag_settings` with `{effortLevel}` / `{fastMode}`; verified accepted by Claude 2.1.201 |
| codex | model | `model/list`; stored on the session and applied through `turn/start` / `thread/settings/update` |
| codex | effort | selected model's `supportedReasoningEfforts` |
| codex | fast | selected model service tier whose id/name/description advertises fast/priority |
| codex | approvals, sandbox | `approvalPolicy` and `sandboxPolicy` turn/thread overrides |
| codex | mode | real `collaborationMode/list` + `collaborationMode` setter; app-server requires `experimentalApi` capability |
| codex | skills | `skills/list`, emitted as `$` commands |
| opencode/gemini ACP | auto-approve | local `autoApprove` toggle answers `session/request_permission`; gemini also maps the start value to `--yolo` |
| pi | model | RPC `get_available_models` / `set_model {provider, modelId}` |
| pi | thinking | RPC `set_thinking_level` |
| pi | commands | RPC `get_commands`, emitted as `/` commands |
| opencode/gemini ACP | model, mode | `session/new` `configOptions` / ACP `modes`; opencode setter is `session/set_config_option` (`session/set_config` is not supported by 1.17.13) |
| opencode/gemini ACP | commands | `available_commands_update`, emitted as `/` commands; opencode accepts slash command prompt text and routes it to `session.command` |

Keyboard shortcuts are defined once in `src/keymap.ts` and the status row plus
keyboard handler both call the same `setOption` path:

| shortcut | action |
|----------|--------|
| `Shift+Tab` | cycle mode-like option |
| `Ctrl+Shift+M` | cycle model |
| `Ctrl+Shift+P` | open model select |
| `Ctrl+Shift+T` | cycle thinking/effort |
| `Ctrl+Shift+F` | toggle fast mode |
| `Ctrl+Shift+L` | toggle plan mode |
| `Esc` | interrupt running turn, else close popup/overlay |
| `Ctrl+/` or `?` on an empty input | shortcut help overlay |
| `ArrowDown` / `Ctrl+N` | next item while a `/`, `$`, or `@` popup is open |
| `ArrowUp` / `Ctrl+P` | previous item while a `/`, `$`, or `@` popup is open |
| `Enter` / `Tab` | accept the selected popup item |
| `Ctrl+J` | insert newline by default; set `agentChat.keys.ctrlJ` to `"menu"` in `~/.config/cmux/cmux.json` to make it next-item while a popup is open |

When focus is in a text input and no popup is open, plain `Ctrl+<letter>`
combinations are left to the native macOS text editor bindings.

Typing `@` at a token start opens the same popup UI for file references. The
server lists git-tracked/untracked files for the cwd when possible and falls
back to a capped directory walk outside git repositories.

Adding a provider is either one registry entry (ACP-speaking: id + cmd) or one small adapter file (bespoke stream-JSON). Nothing in the UI changes.

### Known env quirks (this machine)

- gemini: Google now blocks Gemini Code Assist for individuals (`IneligibleTierError`, migrate-to-Antigravity). ACP handshake works; auth fails upstream. Registry keeps it; it errors fast in the UI.
- claude: TTFT is ~1-2 min on this machine when an `ANTHROPIC_API_KEY`/proxy auth source is active; the UI streams fine once tokens start.

## What the real cmux feature needs beyond this MVP

- A native `AgentChatSurface` (or a pinned browser surface type) with the composer as the new-workspace view; the server becomes a cmux-owned daemon keyed by workspace, sessions persisted to disk (each provider already has resume: claude `--resume`, codex thread ids, ACP `session/load`).
- Permission requests routed to native cmux dialogs/notifications instead of the auto-approve toggle; ACP already models this, and claude gets it via `--permission-prompt-tool` or the ACP adapter.
- Attach chat sessions to the workspace's terminal/worktree (cwd = worktree, show diffs via `cmux-diff`), and a "open in terminal" escape hatch that resumes the same session in the provider's TUI (`claude --resume <id>`, `codex resume <thread>`).
- Provider registry in `~/.config/cmux/agents.json` so users can add any ACP/stream-JSON agent without code.
