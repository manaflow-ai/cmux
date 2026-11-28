# Orchestration to-do

Status 2026-09-17: every item below is implemented and tested (`cargo test`,
plus live runs against Claude and pi sessions). Kept as the design record.

What acpmux should add so agents can drive other agents through it. Drawn
from reading acpx (66208a7) and herdr (14351f1) source, kept to what fits a
daemon that sees every ACP message, not a terminal emulator that scrapes
screens.

Done already: named persistent sessions, `run`, `send --no-wait`, `wait`
(first-to-resolve, `--all`, exit 2 on a pending permission, 3 on timeout),
`last`, `pending`, `session allow|deny`, `ls --status|--pending`, `--json`,
hosts over ssh, export/import, per-session event log with seqs.

## Phase 1: an agent inside a session can orchestrate

1. **Caller context.** Spawn every agent with `ACPMUX_SESSION_ID`,
   `ACPMUX_SESSION_NAME`, `ACPMUX_SOCKET`, `ACPMUX_ENV=1`. Add `--current`
   to every session-taking command (`last --current`, `send --current`,
   `wait --current`). Strip a parent agent's own identity variables from
   children so a nested launch is not taken for its parent (herdr drops
   `CODEX_THREAD_ID`; we already drop Claude's env under `CLAUDECODE`).
2. **`acpmux skill`.** A SKILL.md bundled with `include_str!` so it always
   matches the binary. First rule: check `ACPMUX_ENV`. Teaches: read ids
   from `--json`, never guess names; `wait` defaults are enough; a timeout
   does not prove the prompt was not delivered, read `last` before
   retrying; do not delete sessions you did not create.
3. **`send` on a busy or blocked session reports, never refuses.** The
   prompt queues (or steers with `--steer`). The reply says what it is
   behind: `queued behind 1 pending permission and 1 running turn`, and
   `--json` carries `queuedBehind: {permissions, turns}`. Exit 0.
4. **Sequence-gated waits in the hub.** Give every session a monotonic
   `stateSeq` bumped on status, permission and turn-end changes, returned
   by `ls --json` and `session info`. Move `wait` server-side:
   `_acpmux/wait {sessions, until, afterSeq, timeout}` snapshots the seq,
   returns at once when the state already matches, otherwise subscribes.
   No 1.5 s polling, no missed transition between list and subscribe.
5. **`wait --until STATE`.** `ready` (turn ended), `permission`, `closed`,
   `done` (ended while no TUI or web client was attached: the unread bit
   the sidebar already keeps, set by the hub not the client), `running`
   (prompt accepted; the acpx/herdr "did it start" gate). Default stays
   "first of ready or permission".
6. **Stalled-prompt detection.** If a prompt produces no `session/update`
   or permission request within N seconds, `send` returns exit 1 with
   `prompt_stalled` and the current status. The turn keeps running; the
   caller decides.

## Phase 2: script hygiene

7. **Stable exit codes everywhere.** 0 ok, 1 runtime or agent error,
   2 usage, 3 timeout, 4 no such session, 5 every permission in the turn
   denied, 130 interrupted. One mapping function. Document in README.
8. **One error envelope.** With `--json`, errors go to stderr as
   `{"error": {"code", "detail", "message", "sessionId", "retryable"}}`
   and nothing else is printed on stdout. `code` is the small stable set;
   `detail` is free text such as `agent_spawn_enoent` or
   `permission_prompt_unavailable`.
9. **`--timeout` on `send` and `run`.** Cooperative `session/cancel`, wait
   up to 2.5 s for `stopReason: cancelled`, then exit 3.
10. **`--on-permission wait|deny|fail`** for `run` and `send`. `deny`
    answers `reject_once` and continues; `fail` ends the turn with exit 5.
    Default `wait` (today's behavior).
11. **`ensure NAME [-a AGENT] [--cwd DIR]`.** Return the session if it
    exists, create it otherwise, print its record. Idempotent for scripts.
12. **`exec`.** `run` with a temporary session purged after the reply.
13. **Turn markers in the event log.** Append `turn_started` and
    `turn_result {completed|cancelled|failed, stopReason, error}` as mux
    events, so a reader knows settlement without inferring it from the
    `stopReason` response. On daemon restart with a `turn_started` and no
    `turn_result`, write `turn_result failed {detail: outcome_unknown}` so
    nobody auto-replays a prompt that may have executed.
14. **`session tail --since CURSOR`.** Cursor = `<sessionId>:<seq>`. A
    seq older than the retained log returns `cursor_expired`, never a
    silent skip. `--follow` continues live. This is acpx `sessions watch`.

## Phase 3: policy and reliability

15. **Permission rules by tool token.** Optional per-session JSON:
    `{"autoApprove": [...], "autoDeny": [...], "ask": [...], "default": ...}`
    matched case-insensitively against tool kind, title, title head, and
    raw tool name; precedence deny, approve, ask, default, then the
    session policy. The five named policies stay as presets.
16. **Config replay on ACP reconnect.** When an ACP harness is
    respawned (stop then send), replay mode, then model, then every
    config option, in that order, and re-assert the model even when
    unchanged so sibling options such as `reasoning_effort` reconcile.
    Claude already resumes by process id and needs none of this.
17. **Retry only when safe.** `run --retries N`: retry a turn only on
    ACP `-32603` or `-32700`, only if no `session/update` was seen, with
    backoff capped at 10 s. Claude's own API retries stay visible as
    today's `API retry n/10` note.
18. **Notifications from the hub.** On two transitions only, permission
    pending and turn ended while unattached: OSC 9 (Ghostty, iTerm2,
    WezTerm) or OSC 99 (kitty) from the TUI, tmux passthrough, and an
    optional `notifyCommand` in config. `wait --notify` for scripts.

## Phase 4: observability for many sessions

19. **`wait --match TEXT | --regex RE`.** Resolve when the transcript
    contains it. Existing text matches at once. Invalid regex is exit 2.
20. **Metadata tokens.** `session tag NAME key=value [--ttl 3600]`,
    stored in meta, shown in `ls --json`, filterable with
    `ls --tag key=value`, and shown in the sidebar subtitle. Lets an
    orchestrator label work without acpmux knowing the semantics.
21. **`daemon schema`.** JSON Schema for every `_acpmux/*` method and
    notification, generated from the Rust types, checked in, embedded,
    and covered by a test that fails when stale.
22. **`session history NAME [--limit N]`.** One line per turn: prompt
    preview, stop reason, tool count, tokens, wall time.
23. **`compare a b "prompt"`.** Same one-shot prompt per harness, run
    serially in one directory, one row each: status, wall ms, tokens,
    permissions asked/denied, first 200 chars of the reply.
24. **`--suppress-reads`** for `--json` output: blank read-tool payloads
    but keep the message shape.

## Not planned

- Screen-state detection, manifests, `seen` tracked by focus: the wire
  gives acpmux the state, and the hub knows who is attached.
- Refusing prompts on blocked sessions: prompts queue.
- Workflow engines (acpx flows) and replay viewers.
- Lease, heartbeat and generation files: the daemon owns the sessions.
