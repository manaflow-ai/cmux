# Background delta sync: the phone's cache stays current while the app is away

Leo, 2026-11-24 08:18Z (relayed): "the syncing can arguably happen in the background too, so deltas can be
sipped and maintained."

Goal: when the app comes forward after 1 minute, 10 minutes, 1 hour or 8 hours away, every cached surface
(workspace list, agent chats, terminal screens) is at most one delta behind, and current within 200 ms p95 on
LTE once the link is up. Bytes spent per background hour stay under a stated bound.

This builds on what exists. It adds no second store, keeps the link parked as cmux#44747 and #47608 made it,
and does not keep it alive in the background (RFD 0049, "What we will not do").

## What the phone holds today, and the cursor each surface has

| Surface | Store on the phone | Cursor the phone keeps | Cursor the host answers |
|---|---|---|---|
| Workspace list | `LiveSnapshotStore` (`head.json`, `tail-<mac>.json`) | none on disk: the tree revision (`known`) is in memory only (`WorkspaceSync.swift:581`) | `list-workspaces {known}` answers `unchanged` or the tree (`tree_revision.rs`) |
| Agent chats | `AgentTranscriptCache` (600 records, 48 MiB) | `lastSeq` per chat, on disk | `_acpmux/attach {afterSeq}`, newest page first on a long gap (`beforeSeq` + `gapFill`) |
| Chat list | in memory | `listSeq` / `listEpoch` | `_acpmux/watch {afterSeq, listEpoch}` answers the rows changed (`row_log.rs`) |
| Terminal screens | none on disk (Ghostty mirror in memory; tab cards are pictures) | **none** | `terminal-resume-v1`: a 4 MiB ring by `offset` + `generation` (`resume_ring.rs`). The phone never sends `resume_offset`. |

So two of the three surfaces already answer "only what changed", but the phone loses the cursor on a relaunch
(workspace list) or never had one (terminal). And the terminal's resume answers up to 4 MiB of missed bytes even
when the screen they produce replays in a few KB.

## What iOS allows in the background

The app is suspended in the background, and its sockets are not serviced (TN2277). What can run:

| Mechanism | Per wake | How often | Notes |
|---|---|---|---|
| `BGAppRefreshTask` | about 30 s (WWDC19 707) | when the system decides, learned from use; off in Low Power Mode and when the person turns Background App Refresh off | resubmit in the handler; always call `setTaskCompleted` |
| Silent push (`content-available`, priority 5) | about 30 s | "two or three per hour" | best effort, newest one kept, none after force quit |
| Notification Service Extension | about 30 s per visible push | one per alert push | our pushes already carry `mutable-content` (`backend/src/push.ts`), and the extension can service a request over a resumed link (`link.rs` tests at 2984-3020) |
| Background `URLSession` | out of process | rate limited, discretionary | HTTP only: cannot reach the daemon's link |
| `beginBackgroundTask` | finite (read `backgroundTimeRemaining`) | on leaving | the park handshake already fits here |

Sources: [BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask),
[WWDC19 707](https://developer.apple.com/videos/play/wwdc2019/707/),
[Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app),
[Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications),
[Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background),
[backgroundRefreshStatus](https://developer.apple.com/documentation/uikit/uiapplication/backgroundrefreshstatus),
[TN2277](https://developer.apple.com/library/archive/technotes/tn2277/_index.html).

No mechanism has a cadence we control. So the design does not depend on any wake: **the foreground catch-up is
one round trip carrying every cursor and a byte budget, and its cost is bounded whatever the time away**. A
background wake runs the same catch-up early, so the one at foreground has less to do.

## Mechanism per surface

| Surface | In the background | At foreground |
|---|---|---|
| Workspace list and chat list | each wake: one catch-up with the list cursors (`known`, `listSeq`), a few KB | the same, before the first paint finishes |
| Chats | each wake: the chats the push names, then the 3 most recently opened, newest page first, 64 KiB per wake | the chat on screen first, its newest page |
| Terminals | none: a screen goes stale in seconds and costs bytes to keep | resume by offset when the missed bytes are under the budget; else one screen replay |

Wakes: the Notification Service Extension on every visible push (the host already pushes on "agent finished" and
"needs input"), and `BGAppRefreshTask` as the backup. Silent pushes are not used: two or three an hour is not a
cadence, and they need a new APNs push type on the host.

## The delta protocol (Rust)

`cmux-mobile-core::catch_up`, phone side, no I/O:

- `Cursors`: per (account, Mac), the list's tree revision and `listSeq`/`listEpoch`, each chat's `lastSeq`, each
  terminal's `offset` + `generation` and the size of its last replay. Encoded into the existing `ReadStore`
  (`read_store.rs`) under kind `cursors`, so a relaunch keeps them; cleared with the store on sign-out.
- `plan(cursors, wake, budget) -> Vec<Request>`: the ordered requests of one wake: lists first, then chats
  (pushed one, then recent), then (foreground only) the terminal on screen. Each carries the cursor and its
  share of the byte budget; the plan stops when the budget is spent.
- `apply(reply)`: advances a cursor only past what the reply holds (`pageThrough`, `through`), so a cut wake
  is resumed, never skipped.

Host side, `cmux-tui-core`: `attach-surface {resume_max_bytes}` (capability `terminal-resume-bounded-v1`): an
exact resume only when the missed bytes fit, else the normal screen replay with `resume:"gap"`. The phone sends
the size of its last replay, so the cheaper of the two is always chosen. A host without the capability ignores
nothing: the phone does not send the field to it.

## Budgets

- Per wake: 64 KiB down, 30 s wall clock, stop early when every cursor is current.
- Per background hour: 256 KiB (lists about 5 KB a wake, chats 64 KiB a wake, at most about 4 wakes an hour as
  iOS schedules them).
- Battery: a wake is one resumed link (one handshake round trip, cmux#51007) and one request per surface; no
  timers in the background.

## Numbers

Measured on `scripts/measure/ios-network-conditions.sh mode=background` (this PR): the real cmux-tui daemon and
acpmux behind the `cmux-fault` shaper; time away simulated by the events an idle Mac and a busy agent produce in
that time. Table: see the PR body.
