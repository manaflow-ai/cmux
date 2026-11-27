# Self-healing cmux-next: design (short)

User ask (2026-10-19): "think from first principles how we can make these types of errors
more resilient and self healing, and do the fixes."

## First principles

1. **A client never shows an error it can fix itself.** Every failure is classified as
   *healable* (stale peer, busy server, dropped connection, crashed/zombie daemon) or
   *needs a person* (missing install, foreign home, refused credentials). Healable failures
   are healed, then retried. A banner shows only after healing failed.
2. **Retrying is safe by construction.** Every mutation carries one idempotency key for its
   whole life, across reconnects. The server dedupes by key (daemon receipts, app
   `ControlIdempotencyCache`), so the client may resend the same request after any transport
   failure. Reads are always safe to resend.
3. **The error says what failed, and the log has it.** "did not start" is not a cause. The
   banner names the cause in one line; the same cause goes to the log the banner names
   (`daemon.log`) and to the unified log, which `cmux errors` (a33's journal) harvests.
4. **A daemon that outlives its binary is handed off, not killed.** acpmux `daemon shutdown`
   keeps agent hosts; the next daemon adopts them. A handoff is triggered by evidence
   (executable file gone, peer refused), never by a plain build difference (builds share the
   Chief home, so that would make two builds restart each other's daemon).
5. **Liveness is checked by state, not by `kill(pid, 0)`.** A zombie answers `kill(pid,0)`
   with success; it is dead.

## Errors from 2026-10-18 and what heals them

| # | Error | Root cause | Heal |
|---|-------|------------|------|
| 1 | "acpmux did not start" banner in Chief chats | Daemon 8886 kept running the binary Sparkle deleted; peer check (`proc_pidpath`) refused it; Chief tabs never hand off | 6754a06a160 (a32, landed) hands off at `HomeBrainHost.start`. **New:** a Chief tab whose handshake is refused asks the Chief brain keeper to heal now: hand off the stale daemon (hosts adopted), stop the stale host; the brain watch relaunches host + bundled acpmux. Banner names the cause; cause appended to `daemon.log`. |
| 2 | CLI `transport closed before response`, `Broken pipe`, `mutation.outcome_unknown`, `did not finish within 1999 ms` | Daemon/app busy (a51: registry lock held by session.events reads; 64-connection limit) | a51 fixes the daemon side (f6ad68b5436, own lock-free reader, `refused` line). **New, CLI side:** daemon-route requests (mutations with their key, reads) reconnect and resend up to 3 times with backoff 0.25/1/3 s after a transport failure; app-route requests do the same on a dropped connection and on a `timeout` that says `not_run`. `outcome_unknown` is printed only after the retries fail. |
| 3 | `cmux terminal write` Enter not taking | The write's connection dropped after the request was sent | Covered by #2: `terminal.input.write` is a keyed mutation and the daemon keeps an input receipt per key, so a resend never types twice. |
| 4 | Orphan terminal hosts, stale daemons of old builds, shared acpmux lock | Old DEV builds' processes never stopped | a65 (keep-3-newest stops a removed build's processes), #20405. Not redone here. |
| 5 | Agent sessions stopped by errors | — | a54 auto-resume (bc4d23fd3f9). Not redone here. |
| 6 | Zombie daemon counted as alive | `crashed()` used `kill(pid,0)` | **New:** zombie (`SZOMB`) or gone = crashed, so a reconnect restarts a crashed own daemon. |

## Not in this change (left)

- A periodic watchdog that restarts a *wedged* (alive, not answering) daemon. A wedged acpmux
  cannot answer its own `shutdown`, and killing it ends pooled agents; this needs a
  daemon-side health endpoint with its own thread first. The pane retry + handoff covers the
  stale-binary case, which was tonight's.
- Version/protocol check on every connect for cmux-tui (`cmux-tui` already refuses with a
  capability check, `cli/skew.rs`); a stale cmux-tui after an update still needs the app's
  existing "Restart cmux-tui" path (cx-jniyz.1).
- Adaptive timeouts from measured latency: retries with backoff come first; measured
  timeouts would need a latency store shared across CLI runs.
