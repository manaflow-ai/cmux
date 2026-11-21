# Messaging-grade send: local ack, resume, push wake

Leo, 2026-11-21: "think texting, [a consumer messaging app], and becoming the motherf***ing telecom
company".

The goal: a chat message or a keystroke sent from the phone feels sent the moment the finger lifts,
whatever the link is doing. The phone acknowledges it locally at once and reconciles with the Mac
later; a link that dropped comes back fast enough that the reconcile is invisible; and the Mac can
wake the phone when it has news. Targets are at the end ("Phases and targets").

This page has three parts: what a send costs today (from the code and the verify pages), what
consumer messaging apps do, and the design that maps that onto the phone link.

## 1. Today's send timeline

Numbers are measured where a verify page measured them (cited), else estimated from the code
(marked "est."). "Direct" is WireGuard or WebRTC on a direct path; "LTE" uses the 80 ms round trip
of the reconnect rig (`cmux-mobile-link-ffi/tests/reconnect_steps.rs`).

### A chat send (warm link)

| # | Hop | Code | Time |
| --- | --- | --- | --- |
| 1 | Tap Send: the store trims, picks or reuses a `promptId`, calls the source | `AgentChatStore.send(prompt:)` | < 1 ms est. |
| 2 | The hub writes the prompt, or holds it when the link is not ready (a held prompt is flushed on `linkUp`, or 500 ms after the hold when a link is up) | `AcpmuxHub` `sendPrompt`, `hold`, `flushHeldPrompts` | 0 ms ready; 500 ms to 10 s held |
| 3 | JSON-RPC `session/prompt` on the `acpmux` channel: a **bulk** channel, round robin with every other bulk channel in 16 KiB frames | `link.rs` writer; PROTOCOL.md "Lanes" | 0 ms idle; under a 10 Mbit/s flood a bulk frame waited 2 to 150 ms median, 1.1 to 1.4 s p90 on WireGuard over TURN (verify/terminal-input-lane.md, "Echo in B") |
| 4 | Phone to Mac, one way | network | ~1 ms LAN; ~40 ms LTE; +7 to 75 ms TURN (half the TURN `send` ack, terminal-input-lane.md) |
| 5 | Mac host checks the request and forwards to acpmux | `acpmux_policy.rs` | 1 to 5 ms est. |
| 6 | acpmux records the prompt (once per `promptId`) and emits `user_message` | acpmux | 5 to 20 ms est. |
| 7 | Mac to phone, one way | network | as 4 |
| 8 | The store applies `.userMessage` and the bubble draws | `AgentChatStore` `.userMessage`; SwiftUI | 10 to 100 ms (verify/fast-connect.md, "Reply to row on screen") |

Reading the store, the sent bubble is drawn from acpmux's `user_message` (step 8), so **perceived
send lag today is a full round trip plus the Mac's work plus a render**: about 20 to 130 ms on a
direct path, 100 to 250 ms on LTE, seconds behind a flood on TURN, and up to 10 s while the link
is coming back (step 2; past 10 s the draft comes back to the composer with "Not sent"). Nothing
the person sees says "queued" in between.

The prompt reply itself (`connection.reply(to:)`) only comes at the turn's end (24 h timeout,
`AcpmuxConnection` line 85), so it is not a delivery ack.

### A keystroke (warm link)

| # | Hop | Code | Time |
| --- | --- | --- | --- |
| 1 | Key into the session's input queue; predictive echo draws a glyph only after two echoed characters and when the measured echo is slower than its threshold | `DaemonTerminalSession`, `terminal_prediction.rs` | < 1 ms est. |
| 2 | `send` on the `daemon` channel opened on the **input lane** (control, then input, then bulk) | PROTOCOL.md "Lanes" | queueing ~0 even under a flood |
| 3 | `send` ack (phone to Mac to phone) | verify/terminal-input-lane.md | direct 0.5 / 0.8 ms (median / p90, LAN); TURN 14 to 84 ms |
| 4 | Echo of the key on screen (terminal output, main stream) | same | direct 2.0 / 2.9 ms under flood; WebRTC TURN 16 / 84 ms; WireGuard TURN 150 / 1093 ms |
| 5 | Link down: keys held up to 10 s (`inputHoldLimit`, 16 KiB), then **all** dropped, never only the oldest | `DaemonTerminalSession.expireInput` | 10 s bound (termfix-r13 D5: a command typed in an outage ran 15.4 minutes later) |

Keys already feel local on a direct path. The gaps are a slow path (TURN) where echo is the only
feedback, and a link that is coming back.

### Resume

| Case | Measured |
| --- | --- |
| Foreground, link still up | median 15 ms, p95 19 ms (fast-connect.md "Warm reconnect") |
| Cold launch, process start to the Mac logging link up | median 687 ms, p95 739 ms (verify/perf-latency.md, round 2) |
| `offer_sent` to `answer_received` through the hub | 58 to 111 ms (fast-connect.md) |
| Background longer than a keepalive with the sockets cut (NAT forgot them) | timed per step by `reconnect_steps.rs` (no committed result); a reused socket that does not answer costs up to `STALE_PROBE` 2.5 s before the fresh dial wins |

Today a resumed link is a new link: new signaling (or a probe of the old socket), a new
WireGuard handshake, a new inner TCP stream to `:7420`, the channel `open`s, and only then the
held sends, from Swift, in order, one awaited write at a time (`flushHeldPrompts`).

### Push

The Mac posts `POST /v1/devices/:id/notify`; the backend sends a visible APNs alert (question,
permission, finished, failed, Chief, terminal) with `mutable-content` for the rich content
(PROTOCOL.md "Push notifications"). No push wakes the link. A reply typed in a notification goes
through the sealed reply mailbox when the link is down (`mailbox.rs`), and the app keeps replies
for a retry in `PushOutbox` (files in the app group, 15 min max age).

## 2. What consumer messaging apps do

From public engineering descriptions and the platform and protocol specifications (sources at the
end):

1. **Client message ids and an optimistic local ack.** The client makes the message's id before it
   sends anything, writes the message to its local store and shows it at once with a "pending"
   mark (a clock). The server's ack moves it to "sent" (one tick), the recipient's device ack to
   "delivered" (two ticks). The person never waits on the network to see their own message.
2. **Idempotent server dedupe.** The server keys each message by (sender, client id). A retry after
   a lost ack is the same message: stored once, acked again with the first outcome. This is what
   makes blind retries, and 0-RTT replays, safe.
3. **A persistent, ordered outbox.** Unsent messages live in the client's database, survive the app
   being killed, and are retried on every reconnect in conversation order, with a visible "failed,
   tap to retry" only after a real failure.
4. **One warm connection.** While foregrounded the client keeps a single long-lived connection,
   with keepalives tuned to stay under NAT and carrier idle timeouts and coalesced with other
   traffic so the radio wakes once.
5. **Session resumption and 0-RTT.** A reconnecting client resumes cryptographic state instead of
   a full handshake: TLS 1.3 session tickets and early data (RFC 8446 §2.3), QUIC 0-RTT (RFC 9000,
   RFC 9001 §4.6), or a Noise "pipe" that uses the server's cached static key for a zero-round-trip
   first message (Noise Protocol Framework §10.4). The first flight carries application data, which
   is why it must be idempotent (RFC 8446 §8: early data can be replayed).
6. **Push to wake.** In the background the connection is closed and the server pushes. On iOS a
   visible alert with `mutable-content` runs the app's Notification Service Extension for up to
   about 30 s, which can fetch or decrypt content; a silent `content-available` push is low
   priority, throttled (Apple: "don't try to send more than two or three per hour"), and never
   delivered to a force-quit app. Apps lean on the extension, not on silent pushes, for anything
   that must happen.

## 3. The design for the phone link

### 3.1 A Rust outbox with client ids (phase 1 in this PR)

`cmux-mobile-link` `outbox.rs`, pure (no clock, no I/O), one per phone app:

- Every send gets a **client id** made on the phone, and a **stream** (a chat session, a terminal
  surface). The chat's ids are the existing `promptId`s; keys get a UUID per `send` batch.
- `enqueue` answers the **local ack** at once: `Pending`. The same id again is the same send
  (`duplicate: true`), never a second one.
- `take_sendable(max_bytes)` gives what to write now, oldest first in each stream, each once per
  link (`link_up` starts a link); written, it is `Sent`. `max_bytes` bounds a resumed link's first
  flight (3.4).
- `host_ack(id, Delivered | Refused(reason))` settles it. A refusal fails the send **and every later
  send of its stream**; so does an expiry. A stream never delivers a send after an earlier one
  failed (a command's tail must not run alone).
- `link_lost` turns everything written and unanswered back to `Pending`, marked `resend`, aged from
  the loss. `expire(now)` fails what waited for a link longer than its kind's hold (10 s for keys
  and prompts: today's `inputHoldLimit` and `heldPromptWindow`). A send written to a live link
  never ages: a slow link is not an outage.
- `drain_events` gives every state change (`Pending`, `Sent`, `Delivered`, `Failed(reason)`) for
  the FFI layer to surface: the bubble's clock, tick, and "Not sent" come from here, not from
  Swift's own queues.
- `snapshot`/`restore`: prompts survive an app restart (restored as resends, aged from the
  restore); keys never do.
- Settled ids are remembered (1024) so a late duplicate enqueue or answer changes nothing.

It replaces two Swift queues that do the same job separately and in memory only:
`AcpmuxHub.heldPrompts` and `DaemonTerminalSession.input`'s detached hold.

### 3.2 Local ack state over FFI (phase 2)

A uniffi object `SendOutbox` in `cmux-mobile-link-ffi` owns the `Outbox`, its clock, its expiry
timer (`next_expiry_in`) and the durable file (written atomically in the app group, next to
`PushOutbox`'s). Swift calls `enqueue` and draws the bubble from the returned `Pending` in the same
frame; it subscribes to `AckEvent`s for the rest. `Delivered` for a prompt is acpmux's
`user_message` with that `promptId` (or the queued-prompt record), not the turn's end. The link
side calls `link_up` / `link_lost` / `take_sendable` from the link's own events, so the flush is
Rust's, one batched write, not Swift's one-awaited-write-at-a-time loop.

### 3.3 Dedupe on the Mac host (phase 1 type, phase 3 wiring)

acpmux already runs a `promptId` at most once and checks its session log for a `resend`. Keys have
no id: a `send` whose answer was lost is either dropped by the phone (today) or risks a doubled
Return. `cmux-mobile-host` `send_dedupe.rs` `SeenIds` (in this PR, not wired) remembers ids per
phone (4096, far more than a phone holds in 10 s) and answers a repeat with the first copy's
outcome (`Duplicate(Some(ack))`) or "still running" (`Duplicate(None)`). Phase 3 adds an optional
`clientId` to the daemon `send` request (older Macs ignore it), checks it in the host's daemon
policy, and answers `{clientId, ok}` on the input lane.

### 3.4 Resume with a cached session: the first queued send in the first flight (phase 4)

WireGuard already gives us most of a session ticket: a session's keys stay valid for 180 s
(`REJECT_AFTER_TIME`), and a peer roams to the source address of any authenticated packet. So:

- **Park, don't close.** The Mac keeps a link whose phone went silent "parked" for a grace period
  (proposed 120 s, within the key lifetime) instead of closing it at the 20 s keepalive timeout;
  the WireGuard session and the inner TCP stream to `:7420` stay. The phone does the same with its
  side when the app is suspended.
- **Resume = send.** On foreground, the phone writes `take_sendable(first-flight budget)` straight
  onto the parked stream through the existing WireGuard session to the last confirmed endpoint:
  zero round trips before the first byte of the first queued send leaves. Roaming moves the Mac's
  reply to the phone's new address. If keys are older than 180 s, WireGuard's own 1-RTT handshake
  runs and the queued bytes go right behind it.
- **Race the slow path.** In parallel, the existing fast dial (signaling, `wg-init`) runs as today.
  Whichever stream answers first carries the outbox; the loser is closed. Because every send has an
  id and the Mac dedupes, a send carried by both is still run once (the replay rule of 0-RTT).
- Path choice stays the dialer's (other lanes own `dial/` and path selection); this only changes
  what the first bytes on a resumed stream are.

### 3.5 Push wake when the Mac has news (phase 5)

- Every alert push the Mac already sends runs the Notification Service Extension. The extension
  resumes the parked link (3.4) when it can, within its time and memory budget, to fetch what the
  tap will show and to reconcile the outbox (`Delivered` / `Failed` for sends from before the app
  was suspended), writing the result to the app group so the app opens on fresh state.
- For news with no alert (a send's delivery, a quiet Mac state change), the Mac asks the backend
  for a background push (`apns-push-type: background`, priority 5, `content-available: 1`),
  coalesced per phone and rate limited well under Apple's budget. It is a hint: nothing depends on
  it, because the foreground resume and the extension cover the same ground.
- The phone's signaling `hello` and `presence` already carry the Mac's freshness (`quietMs`,
  design/mac-presence-keepalive.md); a `pending` count of undelivered acks there lets a cold open
  know to resume before the person taps.

### 3.6 Keep the link warm while it matters

The link already pings every 15 s on the radio-aligned grid (`keepalive.rs`, Align Keepalives).
While the outbox holds unsettled sends, or a turn the person started is running, the phone keeps
the link (and asks iOS for its short background task) instead of letting it drop the moment the
app is backgrounded, so the reconcile usually needs no resume at all.

## 4. Phases and targets

Metrics (one harness each, before and after from the same harness):

- **Perceived send lag**: tap (or key) to the person's own bubble or glyph on screen, pending
  state included. App mark `send_local_ack` minus the touch's timestamp.
- **Send to delivered**: tap to `Delivered` (the Mac's ack).
- **Resume to first byte**: foreground (`.resume`) to the first byte of the first queued send
  arriving at the Mac (`reconnect_steps.rs` gains this step; the Mac logs the arrival).
- **Exactly once**: in a chaos run (1000 sends across chat and keys, the link killed at random),
  every send is delivered once in stream order, or failed visibly with its whole stream tail.

| Phase | What | Target |
| --- | --- | --- |
| 1 (this PR) | `outbox.rs` (local ack, dedupe by id, reconcile on host ack, resend on the next link, ordered, expiry by stream tail, durable prompts) and the host's `send_dedupe.rs`; unit tests; not wired | tests green |
| 2 | `SendOutbox` over FFI; the chat bubble and its clock/tick/"Not sent" come from `AckEvent`; `heldPrompts` and the keys' detached hold move to Rust; durable file | perceived send lag p95 ≤ 16 ms (one frame at 60 Hz) for chat, from 20 to 250 ms today; no change for keys (already local) |
| 3 | `clientId` on daemon `send`, `SeenIds` in the host's daemon policy, `{clientId, ok}` acks; a lost key `send` is resent instead of dropped | exactly once: 0 doubled, 0 lost in the chaos run; send to delivered p95 ≤ path RTT + 10 ms on a direct path |
| 4 | Parked links on both ends, resume onto the parked stream, the first flight carries the outbox, racing the fresh dial | resume to first byte p95 ≤ 1 RTT + 20 ms after up to 120 s in the background (≤ 100 ms on the 80 ms LTE rig); ≤ 700 ms p95 after a long background (today's cold link-up p95 is 739 ms) |
| 5 | Extension resume on alert pushes, coalesced background pushes, `pending` in presence | the app opens on reconciled state after a push: 0 stale "pending" bubbles at open in the push harness |
| 6 | Chaos harness in CI and per-phase dashboards | the four metrics tracked per build |

## 5. Open question for Leo (taste)

The hold window is 10 s for both keys and prompts (his 2026-11-12 LTE note set the chat's to the
terminal's). Messaging apps hold a message for days and send it when the network is back. For
**prompts only** (keys keep 10 s: stale keys are dangerous), should a queued prompt wait longer
(say until the link is back, showing "queued" with a cancel), now that it is durable and
deduplicated? The outbox takes it as one constant (`SendKind::hold_ms`).

## Sources

- RFC 8446, TLS 1.3: §2.3 0-RTT data, §4.6.1 session tickets, §8 0-RTT and anti-replay.
  <https://www.rfc-editor.org/rfc/rfc8446>
- RFC 9000, QUIC transport, and RFC 9001 §4.6, 0-RTT. <https://www.rfc-editor.org/rfc/rfc9001>
- The Noise Protocol Framework, §10.4 "Noise Pipes" (0-RTT with a cached static key).
  <https://noiseprotocol.org/noise.html>
- WireGuard whitepaper, §5.4.6 timers (`REJECT_AFTER_TIME` 180 s) and §2.1 roaming.
  <https://www.wireguard.com/papers/wireguard.pdf>
- Apple, "Pushing background updates to your App" (priority 5, throttled, two or three per hour)
  and "Modifying content in newly delivered notifications" (Notification Service Extension).
  <https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app>,
  <https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications>
- Apple Developer Forums, background pushes are never guaranteed and not delivered to a force-quit
  app. <https://developer.apple.com/forums/thread/757094>
