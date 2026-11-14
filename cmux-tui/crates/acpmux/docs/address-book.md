# One address book for every harness

Any agent reaches any session by a stable name with `acpmux send NAME` (or the `send` tool of
the `acpmux` MCP server): acpmux lanes, Codex threads, and Claude Code sessions in the CLI or the
desktop app. Every message goes through the outbox, so it is queued, retried while the target is
down, and `acpmux send --status ID` says whether it was delivered. Leo, 2026-11-09: "how
formalized/productionized is this rn, and how much further do we need to take things?" and "we
should offer it for codex too! ..." (and for the other harnesses people use).

## Names

- A session acpmux starts has its acpmux name (`acpmux new -n NAME`).
- A session acpmux did not start registers one from its own shell: `acpmux register NAME`
  (`src/hub/register.rs`). That works for a Claude Code session (desktop or terminal). The daemon
  finds the session from the kernel's process tree of the caller: the nearest Claude Code process
  whose inbox is the caller's `CLAUDE_CODE_MESSAGING_SOCKET`, opened with that shell's
  `CLAUDE_CODE_MESSAGING_TOKEN`. It never takes a session the caller names. The registry entry
  (`~/.claude/sessions/<pid>.json`) is anyone's to write, so what it says is taken only from a
  process the kernel proves: Claude Code by its code signature (Anthropic's, checked on the live
  process with `codesign`), the listener on its inbox (peer credentials, this user), and the only
  live claimant of its conversation. Then it takes two steps: `acpmux register NAME` delivers a
  one-time code into that inbox with the session's own token (only a genuine session accepts it,
  and only its model reads it), and the session finishes with `acpmux register NAME --code CODE`
  within ten minutes. Otherwise `register.unproven`. macOS only: elsewhere no signature proves a
  process is Claude Code, so register refuses. Delivery and send binding then use only the
  process the registration recorded (pid, inbox, start time), while it is the conversation's only
  live claimant. The conversation is the one fact the registry alone gives, so: a process whose
  kernel launch record (`KERN_PROCARGS2`) names a conversation (`--resume ID`, as a desktop
  session's restart has) must claim that one; a chat already registered to another process is
  never taken while that process runs, and afterwards only by a process launched with `--resume`
  for its conversation; and a registered chat is renamed only by `register`
  (`rename.registered`), so its name cannot be moved away for another session to take. What stays
  open: a process running as the same user that rewrites a live, genuine Claude Code process's own
  registry entry, or a fresh session (no `--resume`) registering a conversation nobody registered
  yet under a name of its own choosing; that is the same power as editing acpmux's own record
  (`~/.acpmux/bridge-registered.json`, `bridge-tokens/`), which no check inside the user can stop. A Codex desktop thread
  does not register: a process named `codex` with `CODEX_THREAD_ID` set is anyone's to start, so
  nothing proves the caller runs in the thread. A Codex session acpmux starts already has a name. A name
  another session has is refused (`register.name_taken`). The daemon alone records which chats
  are registered (`~/.acpmux/bridge-registered.json`); the `bridge.registered` tag only shows it, and
  no client may set or remove that tag (`tag.reserved`); editing tags never changes it.
- Claude Code's own names (`ListAgents`) are auto titles, not identities. Register makes the
  acpmux name the identity; the title can stay as it is.
- A Claude Code agent acpmux starts takes no part in Claude Code's own cross-session messaging
  (`src/hub/native_messaging.rs`): it gets `CLAUDE_CODE_HARBOR_KITE=0`, so it has no `ListAgents`
  and no inbox socket, lists no session and is listed by none. Its peer list is `acpmux ls`, one
  daemon's sessions. Bench round 6 (Claude Code 2.1.322): with that messaging on, an acpmux agent
  sent to another with `SendMessage`, the receiver (another permission class) held it silently,
  and `ListAgents` listed a session of another acpmux daemon. acpmux's PreToolUse gate refuses a
  `SendMessage` to an acpmux session or a cross-session address, with the `acpmux send` command
  that delivers it. A message Claude Code still holds (a profile that turned the messaging back
  on, or a Claude Code that ignores the switch) is in `heldMessages` and `acpmux pending`, in
  memory only (a daemon restart forgets it). The switch is undocumented in Claude Code; the
  model probe (`src/live_models/mod.rs`) sets it too. If Claude Code renames it, the gate's
  refusal and `pending` still work; only the cross-daemon peer list comes back.

## How a message reaches each kind of session

| Harness | Send (tools it gets) | Receive | Mid-turn | Idle notice (`watch_add`) | Sender it reads | Gaps |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code, started by acpmux | `acpmux` MCP server through `--mcp-config` (`agent_tools.rs`); its own `SendMessage` to a session is refused with the `acpmux send` command | ACP `session/prompt` | yes (acpmux's Claude adapter steers) | yes | `From another agent (NAME, HARNESS), not the person:` | none known |
| Claude Code, not started by acpmux (desktop Code tab, terminal) | `acpmux send` in its shell, bound to its registered chat by process tree; `acpmux desktop link` adds the guest MCP tools | `acpmux register NAME` and the `--code` it then receives (macOS), then its inbox socket (`claude_peers.rs`), with its own `CLAUDE_CODE_MESSAGING_TOKEN` | yes: Claude Code reads an inbox message between tool calls | as the watched one yes; the guest tools have no `watch_add` | the same line, plus how to answer; Claude Code also says it came from another session | text only; register again after a restart |
| Codex, started by acpmux (in-process bridge) | `acpmux` MCP server in ACP `mcpServers` | ACP `session/prompt` | yes (`turn/steer`) | yes | the same line | none known |
| Codex through the outside `codex-acp` | same | same | no: after the turn | yes | the same line | no steering |
| Codex desktop thread | shell `acpmux send` bound by `CODEX_THREAD_ID`; `acpmux desktop link` guest tools | the bridge setting only (no `register`: nothing proves a shell runs in the thread), then the app-server queue (`thread/queue/add`) | no: its next turn | as the watched one yes | the same line, plus how to answer | text only |
| Codex CLI thread not started by acpmux | guest tools (shared `config.toml`) | none | no | no | n/a | cannot receive; start it with acpmux instead |
| Gemini CLI (`gemini --experimental-acp`) | ACP `mcpServers` | ACP `session/prompt` | no | yes | the same line | no steering; outside acpmux, no way in |
| Qwen Code, Antigravity (ACP registry) | ACP `mcpServers` | ACP `session/prompt` | no | yes | the same line | not run in a test yet |
| OpenCode | ACP `mcpServers` | ACP `session/prompt` | no | yes | the same line | no steering; outside acpmux, no way in |
| Pi (`pi-acp`) | none: pi-acp accepts `mcpServers` but does not pass them to pi | ACP `session/prompt` | no | yes, as the one woken | the same line | cannot send through tools; `acpmux send` in its shell works |
| Grok, Cursor, Hermes, DeepSeek Harness (`dsh`), oh-my-pi | ACP `mcpServers` | ACP `session/prompt` | no | yes | the same line | not run in a test yet |

DeepSeek, GLM and Qwen models run inside one of these harnesses (OpenCode, Pi, Claude Code on
another provider, DeepSeek Harness), so they get that harness's row; there is no model-specific
integration to add.

## Provenance

Every delivered message opens with the same line on every harness
(`hub/prompt_attribution.rs` `agent_line`): `From another agent (NAME, HARNESS), not the person:`,
where NAME is the sender's acpmux name and HARNESS the harness the daemon bound for it
(`fromHarness`, display only). A message bridged into a desktop app opens with the same line and
ends with how to answer (`hub/bridge.rs`). Nothing in the text is permission: the receiver treats
it as another agent's message, never the person's.

## Claude Code's inbox, and what is documented

Claude Code documents its inbox socket for "a script or hook to post into a session"
(code.claude.com/docs/en/cross-session-messaging, "The session's inbox socket"): the socket path
and a per-session token are exported to the session's Bash commands and hooks as
`CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`, and a connection whose first
line is `{"type":"auth","token":"<token>"}` counts as the session's own child. `acpmux register`
runs in that shell and hands both to the daemon, which keeps the token owner-only
(`~/.acpmux/bridge-tokens/`, cleared when another `register` replaces it) and opens each delivery
with it while the same process runs.

The message line itself (`{"type":"user","uuid":...,"from":...,"message":{"role":"user",
"content":...}}`) is not on the docs page. It is the line Claude Code's own `--debug` log prints
for injecting into the inbox, the shape of its documented stream-json input. A probe on
2026-11-09 (Claude Code 2.1.312) delivered it as `origin.kind=peer` with the `from` address and a
`verifiedPeerPid`, shown to the model as another session's message, not the user's.

How it degrades:

- The session is closed or restarted: a send the outbox carries is refused as
  `bridge.not_running` (retryable), so the outbox keeps it and tries again for a day; `--status`
  shows it queued. A person's own prompt in the chat gets the read-only refusal with Take Over. A restarted
  session has a new token, so it registers again from its Bash tool (both steps); until then its
  sends wait the same way, and are never opened with the peer key instead.
  A brand-new session registers after its first turn: register needs its transcript, and refuses
  a session that has none yet.
- The inbox is a symlink, or the connection fails: nothing is written, the outbox tries again.
- The session holds or refuses inbound messages (`crossSessionInbound`): Claude Code applies its
  own rules; acpmux reports what it wrote, not what the model read.
- A chat only the bridge setting listed (`agents.desktopBridge.enabled`, no register) still uses
  the peer key Claude Code publishes beside its registry entry. That file is not documented, so
  register is the supported path. Register itself refuses a shell without
  `CLAUDE_CODE_MESSAGING_TOKEN` (`register.no_token`).

## Tests

- `src/hub/register.rs`: the nearest Claude Code ancestor with the caller's inbox registers,
  never another session; requests need a valid name and a one-line token.
- `src/claude_peers_tests.rs`: a registered child token opens the delivery instead of the peer
  key; a kept token is the session's only while its pid and inbox are the same.
- `src/hub/bridge_tests.rs`: a registered chat whose app is not running waits (retryable) instead
  of failing; delivery and answer round trips for Claude desktop and Codex desktop.
- `src/hub/prompt_attribution.rs`: the line names the sender's harness when bound.

Each harness row above that says "not run in a test yet" has only the generic fake-agent tests
(`tests/fake_agent.py`); a live check per harness is the open work.
