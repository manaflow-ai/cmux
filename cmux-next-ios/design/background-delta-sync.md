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
[TN2277](https://developer.apple.com/library/archive/technotes/tn2277/_index.html),
[earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate),
[BGProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask).

What each page says, read back on 2026-11-28 (the pages' JSON under
`developer.apple.com/tutorials/data/documentation/`, the archive and video pages as HTML):

| Claim | Apple's words | Page |
|---|---|---|
| A suspended app runs nothing; its sockets may close | "When the app is suspended, no code within the app's process executes." "the system may choose to reclaim resources out from underneath a network socket used by the app" | TN2277 |
| A refresh wake gets about 30 s | "your app will get 30 seconds of run time, each time it's launched, to fetch new content" | WWDC19 707 |
| We pick no refresh time, only a floor | "the system doesn't guarantee launching the task at the specified date, but only that it won't begin sooner." | earliestBeginDate |
| Low Power Mode and parental controls turn refresh off | "Background App Refresh is disabled automatically when a device is operating in low-power mode." "A restricted user ... can't enable Background App Refresh." | backgroundRefreshStatus |
| Silent pushes: 30 s, two or three an hour, best effort, none after force quit | "Your app has 30 seconds to perform any tasks", "don't try to send more than two or three per hour", "the system doesn't guarantee their delivery", "If something force quits or kills the app, the system discards the held notification." | Pushing background updates |
| The service extension: about 30 s per alert push | "Your [didReceive] method has only about 30 seconds to modify the payload and call the provided completion handler." | Modifying content in newly delivered notifications |
| Processing tasks run minutes, at the system's time, interruptible | "Although processing tasks can run for minutes, the system can interrupt the process." | BGProcessingTask |
| Background `URLSession` is rate limited and delayed | "it uses a rate limiter to prevent abuse of background downloads", "The delay increases each time the system resumes or relaunches your app." | Downloading files in the background |

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
- Per background hour: 256 KiB, enforced (`cmux-mobile-core::catch_up::hour`). Each background reply spends what
  it weighed (what came, not what was asked, so a Mac that overshoots shrinks the next wakes) from a sliding
  one-hour window kept with the cursors, so the app and its notification service extension spend from one hour.
  A wake asks its chats for at most what the hour has left after the two lists' 8 KiB estimate; once spent, it
  asks the lists only (a few hundred bytes when nothing changed) and every chat stays behind its cursor for the
  next hour or the foreground. The foreground is not bounded by it: the person asked. Busy Macs push more than
  4 wakes an hour (one per agent turn ending), which is why the bound is enforced rather than assumed.
- Battery: a wake is one resumed link (one handshake round trip, cmux#51007) and one request per surface; no
  timers in the background.

## Numbers

`cmux-mobile-host/tests/catch_up_conditions.rs` `staleness_rows_under_conditions`, one harness for before and
after: the real `services::serve` behind the `cmux-fault` shaper (`link-profiles.json` good-wifi, lte, lossy-3), a
daemon and an acpmux faked over a modelled Mac (busy: a long agent session writing an event every 2 s, two chats
an event every 20 s, the list and the tree changing every minute; idle: one chat and the list every 10 min), the
phone's own `catch_up::service` code. Time away is modelled (heads set per wake), the link is real time. Before:
no background wakes. After: `BGAppRefreshTask` at its 15 min floor (its best case) and, when busy, a push every
10 min. The PR body carries the table.

Earlier:

Measured on `scripts/measure/ios-network-conditions.sh mode=background` (this PR): the real cmux-tui daemon and
acpmux behind the `cmux-fault` shaper; time away simulated by the events an idle Mac and a busy agent produce in
that time. Table: see the PR body.
