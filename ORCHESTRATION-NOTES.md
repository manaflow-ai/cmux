# Terminal orchestration notes

## Fork findings (OSC 7501, terminal agents CLI)

Measured 2026-10-18 on lawrence's Mac against the installed cmux NIGHTLY
(cmux-tui `d4fe007d11e0`, ghostty `ced99dcde2f1`), with Claude Code 2.1.303 and Codex 0.163.0.
The Mac was heavily loaded during every run: load average 250-330 on 18 cores, 103 `claude`
and 127 `cmux-tui` processes, about 1 GB of free pages. All numbers include that load.

### OSC 7501 state

- **The parser and records already exist; nothing new was needed.** The ghostty-next parser is
  `ghostty-next/src/terminal/osc/parsers/program_status.zig`, the Rust binding is
  `cmux-tui/crates/ghostty-vt/src/terminal/program_status.rs`, and the daemon records are
  `cmux-tui/crates/cmux-tui-core/src/program_status.rs` (conformance matrix:
  `plans/cmux-next/osc7501-conformance.md`). Program status is exposed on the CLI as
  `cmux terminal <t> status` (records: app, id, state, kind, progress, msg, title, since_ms,
  updated_at_ms). It also appears in `cmux terminal <t> wait --until idle`, in `cmux agents wait`,
  and as `program_status.changed` session events.
- Verified live: `printf '\e]7501;state=working:app=exptest\e\\'` in a NIGHTLY shell gives a
  `working` record at once, and `OSC 7501 ; ?` is answered before the DA1 reply.
- **Codex 0.163.0 emits OSC 7501** (`app=codex`): `idle` at startup, then `working` when a turn
  starts and `idle` when it ends. This is a correct turn-end signal for Codex.
- **Claude Code 2.1.303 does not emit OSC 7501 in a cmux terminal.** The binary contains the
  emitter (`state=…:app=claude-code`, `OSC 7501 ; ?` probe), but its capability table marks
  `programStatus` as "not asked yet" with `likely: false` for `TERM_PROGRAM=ghostty`. It never
  sent the probe: a `script(1)` capture of a whole turn has 0 occurrences of `7501`. As a result
  `terminal status` stays `[]` during Claude turns. Claude turn ends must come from its cmux hook
  (`cmux agent list`: `running` → `idle`) or from its transcript.

### CLI: `skills/cmux-terminal-agents/scripts/cmux-terminal-agents` (+ `SKILL.md`)

Python 3 (stdlib only) over the cmux CLI. The verbs are `start`, `send`, `wait`, `read`,
`continue`, `list` and `close`. The tool has no agent cap. It never focuses anything, and
`close` closes only workspaces recorded in `~/.cmux/terminal-agents/agents/`. I did not build it
as a Rust `cmux agents` verb: `cmux agents` already exists for topology, snapshot and wait, and a
Rust change could not be tested here without an app build.

Turn-end signals, first to fire wins: Claude transcript `turn_duration` record (local file,
checked every 0.1 s) → cmux hook state → OSC 7501 record → process exit → screen unchanged for N
seconds without "esc to interrupt". The cmux probes run one thread per signal, because one slow
cmux call must not delay the others.

### Experiment numbers (3 test workspaces: exp-t1 claude, exp-t2 shell→codex, exp-t3 claude via `start`)

| Measure | Result |
| --- | --- |
| `workspace create -- claude …` round trip | 0.76 s (tool `start`), 3.4 s (first manual try, more load) |
| `start --wait` to first answer ("ok"), Claude | 7.1 s total |
| Focus before/after `start` | unchanged (checked with `agents snapshot` focus) |
| "Chief agents" sidebar group | created by `start` (grp_a4a953bd…, purple), workspace added |
| Claude turn, send→detected, single write (paste+CR) | 5.3, 6.0, 7.6 s (3/3 correct answers) |
| Claude turn, send→detected, write then `keys enter` | 8.1–13.2 s (two mutations cost 4–8 s under load) |
| Detection lag after transcript turn end (fast loop) | 0.14–0.32 s (6 trials) |
| Detection lag, first version (sequential cmux probes) | 2.4–7.4 s |
| Claude hook `idle` vs transcript turn end | hook arrives 0.5–3.4 s after the transcript record |
| Multi-line prompt via stdin (bracketed paste) | arrived as one message; answer correct |
| `continue --message …` | worked; answer correct |
| Codex turn (xhigh) | 61 s and about 5 min for trivial turns under load; OSC 7501 `idle` record at turn end |
| Codex turn end via OSC 7501 (thread-per-signal version) | detected 0.56 s after the `idle` record; `read` gave "• two" |
| Codex wait, first version | missed (timeout): sequential probes with 6×30 s retries blocked |

Reliability: about 30–50 % of single cmux CLI calls under this load failed once with
`protocol error: the server on this socket does not speak cmux.protocol/2`, `transport error:
Broken pipe`, or `system.ping did not finish within 1999 ms`. A retry with the printed
idempotency key succeeded every time, and no duplicate writes were seen. The "does not speak
cmux.protocol/2" text is misleading: `cli/wire.rs` `run_response` prints it for any frame whose
`type` is not response or stream. Under load the server sends some other frame, so the real
cause is hidden (follow-up: print the frame type).

### Compared with acpmux spawn (as I see it; the parent has the acpmux numbers)

- Terminal agents are the real TUIs. The user can open the workspace and type, and the CLI reads
  the same screen. Turn end is exact for Claude (transcript) and Codex (OSC 7501).
- Costs: one workspace and one `cmux-tui` terminal host per agent, plus the full TUI render. The
  answer text is exact only for Claude (transcript). Codex `read` is screen-scraped and can lose
  long answers that scroll off.
- Startup time is about the same as an acpmux session (CLI create < 1 s, first answer about 7 s).

Cleanup: `close exp-t1 exp-t2 exp-t3` closed all 3 test workspaces; none remain in
`workspace list`. The empty "Chief agents" sidebar group (grp_a4a953bd…) stays for real use.

### Untested

- Codex `read` for answers longer than one screen. Codex permission or trust prompts in a new
  directory: exp-t2 ran in YOLO mode from the user's config.
- Claude permission dialogs: the user's config runs in auto mode. A dialog shows as hook state
  `needs_input`/`blocked` and ends `wait` with that state, but this was not exercised.
- A Rust `cmux agents start/send/read` in the cmux-next CLI. The Python tool is the
  implementation for now.
- The tool on a cmux build other than NIGHTLY `d4fe007d11e0`.

## Parent findings: Chief subagent cap and acpmux comparison

- The cap was `subagents::MAX_LIVE = 16` in `Native/OptChat/optchat-chief/src/subagents.rs`,
  enforced in `brain/spawns.rs` (`register_spawn`, `start_queued`). It is replaced by
  `OPTCHAT_MAX_LIVE_SUBAGENTS` (unset or 0 = no cap, the default).
- The queue lived only in host memory, so a host restart failed queued subagents
  ("the Chief host restarted while it waited"). Queued launches are now saved in the
  SubRecord (`queued_launch`). Older records get their task back from the logged
  `mcp__optchat__spawn` call. On the live NIGHTLY Chief database this logic recovered the
  task, cwd and effort of a46 through a50 (checked read-only with a script that does the same thing).
- acpmux spawn start time (NIGHTLY host.log, 12 queued starts, from "slot is free" to
  "started from the queue", workspace included): median 6.4 s, min 2.2 s, max 10.3 s.
  The terminal path (fork numbers): `start` to first answer 7.1 s, workspace create 0.76 s.
  So the start cost is about the same. Turn-end detection: acpmux knows the turn end from
  the ACP protocol (no lag). The terminal path adds 0.14-0.32 s for Claude (transcript)
  and about 0.56 s for Codex (OSC 7501).
- Recommendation: keep acpmux spawn as the Chief's main path (structured events, no
  screen scraping). Use terminal agents when the user wants a real interactive TUI
  session, or as overflow when acpmux is not available. The real limit is machine load:
  at load average 250-330, about 30-50% of single cmux CLI calls failed once. So a future
  soft cap should be based on load average, not only on free memory.
