# Redial: the shown browser tab keeps its video; terminals follow a Mac restart

Branch `feat-cnx-ios-redial-video`, 2026-10-20 (base
`origin/feat-cnx-ios-hybrid-link` `bb0dd17a1de`). Fixes defects 7, 2 and 4 of
verify/transport-verify-20261019.md (on `origin/feat-cnx-ios-transportverify`).

## Defect 7 (high): the visible tab lost its video after a redial

### Cause

Three things together:

1. On every new link `StreamedBrowserDirectory.linkChanged()` reopened a
   `browser` channel for every model the phone held: every tab it had ever
   shown in this launch, including tabs of workspaces already closed on the
   Mac (nothing dropped a model unless the phone itself closed the tab).
2. Each open with `video: "track"` claims the link's one media lane, and the
   last claim wins (`VideoOut::claim`). The opens raced, so the lane ended on
   whichever channel opened last, often a hidden tab. Nothing ever gave the
   lane back to the tab on screen: its video stayed on the channel.
3. cmux-mobile-host's host limit (4) stopped the least recently used host with a
   viewer. With five reopened tabs that could be the shown tab's host; its
   channel closed `replaced` and the phone only reopened on the next link,
   so the page froze on its last frame.

### Fix

- Phone (`StreamedBrowserDirectory`, `StreamedBrowserModel`):
  - On a new link only a shown tab (on screen, app active, laid out) opens
    again. A hidden tab opens when it is shown, or when the app comes back.
  - When the Mac's workspace tree arrives, models of tabs it no longer lists
    are dropped (`retain(tabs:)`; this phone's pending workspaces keep
    theirs).
  - The model tells the Mac which tab is shown: `rb.visibility` on every
    change, and `visible: false` right after `rb.open` for a stream opened
    while hidden.
  - A page the Mac stopped (`evicted`) opens again at once while shown, at its
    current address, at most twice without a frame in between; then, and for
    a page another viewer took (`replaced`), it says so with a Reopen button.
    A hidden page that was stopped opens when it is shown.
- cmux-mobile-host (`browser.rs`):
  - `rb.visibility {visible: true}` on a channel that asked for the lane and
    lost it takes the lane back: a new claim, a fresh track bridge (so hostd
    is again the main stream's viewer) and a keyframe request to the host.
    The same path serves the WireGuard RTP route, the WebRTC media session's
    track (hybrid) and the WebRTC link's own track: they are routes of one
    `VideoOut`.
  - The host limit stops an idle host first, then a hidden tab's, then the
    least recently used shown one, and closes that viewer's channel
    `evicted` (it said `replaced`).
- cmux-mobile-link-ffi viewer: a frame of the page's stream on the channel clears the lane
  sync, so when the tab takes the lane back its lane frames start at a
  keyframe.

### Found in the live check, fixed

- A cmux-mobile-host restart stops every browser host, so a reopen starts a new
  host: it now starts at the page's current address (it was the tab's first
  address, a blank page for a new browser workspace).
- The Mac's host keeps its last viewer's `rb.visibility`. A page hidden when
  the person left for Settings stayed hidden under the next link's viewer
  (blank, 2 fps). Every new stream now says its visibility right after
  `rb.open`.
- A browser workspace made on the phone streams under its placeholder tab id
  (`new-<id>-t1`) until the Mac names the tab `s<N>`. The model now moves to
  the real id and keeps its host's key, so a redial reopens the same host
  (page and history), not a new blank host for `s<N>`.
- A page counts the views showing it, and starts hidden: when the tab got its
  real id, the new view appeared before the old one disappeared and the page
  ended up "hidden" while on screen (the host stopped painting, 1 fps). This
  was also the second review's finding 2.
- Only the background hides a page (an inactive scene, as a rebooted
  headless simulator stays, still shows it).

## Defect 2 (medium): a terminal stayed "Reattaching…" after the Mac app restarted

### Cause

The phone's terminal session attached by the daemon's numeric surface id.
Surface ids are runtime slots: they survive an app restart while the daemon
keeps running, but a daemon that starts again (a crash, or a version handoff)
restores every workspace with new numbers (`workspace_registry.rs`,
`restore.rs`). The session asked for surface 15, got `unknown surface 15` six
times over 16 s, printed it, and never tried again; keystrokes waited forever.
Worse, an old number can name another terminal after the renumbering.

### Fix

`DaemonTerminalSession` keeps the tab's durable public id
(`terminal_resource_id`, `term_…`, from `list-workspaces`; `terminal_id` there
is the host id, which a daemon restart changes). A reattach first asks `resolve-terminal {terminal_id}`
(allowed by cmux-mobile-host's policy) and attaches to the surface it names; a
terminal the Mac still lacks after the reattach retries ends with "[This
terminal is no longer open on the Mac]" (right after a restart the daemon
answered `terminal_not_found` for a live terminal for about a second; a null
surface, a terminal still being adopted, is retried too); a reattach that runs out of retries says so and the next keystroke
tries again. On a new link a session reattaches when its surface or its
terminal is listed. A daemon without `resolve-terminal` is attached by number,
as before.

## Defect 4 (low): "WebRTC, UDP blocked"

`TransportKind.settingsValue(blockUDP:relayOnly:)`: Block UDP shows only for
WireGuard ("WireGuard, UDP blocked"); WebRTC shows "WebRTC only" or "WebRTC
only, relay only". The Developer footer says WebRTC ignores Block UDP.

## Tests

Failing first (commits `5105b31031f` for the browser and the label,
`9a8a07b0e45` for the terminal), then green.

Swift (`verify/termqa/cmux_mobile_kit-test.sh` on mini-cmux11s):

- `RedialTests`: only the shown tab opens on a new link, a hidden one when
  shown; tabs the Mac no longer lists are dropped and never reopen; the shown
  state reaches the Mac (`rb.visibility`), also for a stream opened hidden; a
  shown page the Mac stopped reopens at its current address; a hidden one when
  shown; two stops in a row, then Reopen; `replaced` offers Reopen and never
  fights back by itself; a shown tab opens when the app comes back; a hidden
  page never opens on layout, and a late hidden open makes the shown tab
  claim the lane again; a placeholder tab's page moves to the real tab id and
  reopens on the same host; a reopen after a hostd restart starts at the
  page's current address.
- `TerminalRenumberTests`: a reattach follows the terminal to its new surface
  (attach and `send` use it, no `[unknown surface]` line); a terminal the Mac
  no longer has ends with a clear line and is never attached by its old
  number; a terminal still being adopted (null surface) or missing for a
  moment (`terminal_not_found` once) is retried and attaches; a daemon without
  `resolve-terminal` reattaches by number. `ReattachSurfacesTests`: a
  renumbered terminal still reattaches on a new link by its public id.
- `TransportDefaultTests.theSettingsValueNamesOnlyTheDebugPoliciesThatApply`.
- Red: the new API did not exist (build errors in the new tests only).
- Green (final commit): `CmuxMobileLiveTests|CmuxMobileBrowserStreamTests|CmuxMobileModelTests|CmuxMobileTransportTests|CmuxMobileShellTests|CmuxMobileWorkspacesTests`,
  428 tests in 111 suites.

Rust (rbx, `cargo test --workspace`, `cargo clippy --workspace --all-targets -D warnings`):

- `cmux-mobile-link-ffi/tests/browser.rs` `the_shown_tab_takes_the_lane_back_over_{wireguard_rtp,the_media_session,webrtc}`:
  tab A on the lane, tab B opens after it and takes it (A on its channel),
  A says `rb.visibility` true and is back on the lane (WireGuard RTP,
  the hybrid media session's track, the WebRTC track), B on its channel.
  Red before the fix: all three timed out at "the shown tab back on the lane".
- `cmux-mobile-host` `browser::tests`: the host limit stops a hidden tab's host
  before the shown one's and says `evicted`; a second viewer of a tab
  `replaced`; `rb.visibility` parsing.

## Reviews (fresh subagents, correctness first)

First review (after the first fix):

| Finding | Severity | Resolution |
| --- | --- | --- |
| `resolve-terminal` answers a null surface while a restarted daemon adopts the terminal; the phone ended a live terminal | must fix | Null surface retries (`aTerminalNotOnASurfaceYetIsWaitedFor`) |
| Every frame reset the auto-reopen count, so two viewers could evict each other forever | must fix | Forgiven only after 20 s live |
| A hidden page opening (layout) still claims the lane, and nothing gives it back | should fix | Hidden pages never open on layout; a stream opened hidden makes the shown tab resend `rb.visibility` true |
| Tab ids are surface numbers, reused after a daemon restart: an old model could start its page in another tab | should fix | Partly: tabs the tree no longer lists are dropped; a model keyed by a reused id keeps its own host key. Open: no generation check |
| The terminal session follows the new surface, but the UI's tab id changes with the next tree | should fix | Accepted: the UI opens the new tab id with a fresh attach (live row `terminal daemon`); the old session ends when its tab goes |
| A reattach that gave up still showed the spinner; a typed retry got one attempt | should fix | No spinner after giving up; a retry starts the backoff again |
| A reopen can start a page for a workspace closed during the drop, before the tree arrives | nice | Accepted (the next tree drops it) |
| A late channel frame costs an extra keyframe in the ffi viewer | nice | Not done (cmux-mobile-link-ffi; costs one keyframe round trip) |
| Older hostd says `replaced` for an eviction | nice | Accepted: the phone offers Reopen |

Second review (after the live fixes):

| Finding | Severity | Resolution |
| --- | --- | --- |
| `shouldReattach` compared the public id with the host id: a renumbered terminal never reattached on a new link | must fix | Matches either id (`aRenumberedTerminalStillReattachesByItsPublicID`) |
| A tab's new view appearing before the old one disappears left the page hidden | should fix | Views are counted; the live kill rows failed on exactly this before the fix |
| The shown tab's reassert can reach hostd before the hidden tab's open (two channels) | should fix | Open: needs visibility in `rb.open` (hostd change) |
| A renamed placeholder's Mac host stays after the tab closes until the host limit evicts it | should fix | Open: hostd stops idle hosts first, so it costs a slot, not the shown page |
| A page laid out before it ever appeared still opened | should fix | Pages start hidden |
| Old-stream frames can reset the reopen window; a static page is forgiven late | nice | Accepted |
| Rename fired for terminal and agent workspaces | nice | Browser workspaces only |

## Live check (2026-10-20, real link)

Rig: `mini-cmuxs-mac-mini-3` (1-minute load 6 to 40, one spike to 169 during
an earlier attempt). Mac: fleet build `cmux-mobile-e2e-00561360` (job
`21874846b908e586ce51e676`, this branch's cmux-mobile-host at `0056136061d`; the
hostd code did not change after it), an unmodified copy run hidden with every
setting through `open --env`. Phone: this branch's Demo build at `28dc1a66b7a`
in one headless iOS 26.5 simulator (`cmux-mobile-redial-ios26`), signed in with the
shared dev credential; another agent's rig (`cmux-mobile-e2e-ce1d3585`) ran on the
same mini and account, so the run chose its Mac by device id
(`CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS=1`) and read hostd lines of its own phone only.
Signaling through the dev Worker, Cloudflare TURN. Driver
`verify/e2e/redial_video.py` (on the verifier's `transport_verify.py`):
every phone action is a tap or typed text. The simulator was rebooted before
each row (its render server stalls input after repeated recordings,
transport-verify defect 8). Evidence on the mini in `~/cmux-mobile-redial-evidence/`
(`<row>/transition.mp4`, `<row>/bench/screen.mp4`, `results.json`).

Each browser row: two browser workspaces opened from the phone (A, then B,
both on `bench.html?scroll=6`), A closed on the Mac, B on screen; then the
event; the overlay read for 30 s; then 12 s of the bench page recorded and
analysed by `browser-track-bench.py`. `switch:<link>` ends on that link (WG
only: WebRTC with the media session off, then WireGuard; hybrid: WebRTC, then
WireGuard; WebRTC only: WireGuard, then WebRTC). The switch leaves the
workspace with the toolbar's Back, which walks the page's history to the new
tab's `about:blank` first, so the row taps Forward after reopening (the same
Mac host's history brings the bench page back).

| Row | Load | Overlay after the event (30 s) | `browser` opens after the event | Host stopped | Bench (12 s after): carrier, glass to glass p50 / p90, fps, stalls > 100 ms, page tap to frame p50 | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Kill cmux-mobile-host, hybrid | 11 | `track`, 31 to 41 fps | 1 | none | `track` (1077 frames), 72 / 143 ms, 28.5 fps, 4, 59 ms | PASS |
| Kill cmux-mobile-host, WireGuard only | 22 | `wg-rtp`, 25 to 42 fps | 1 | none | `wg-rtp` (911), 82 / 140 ms, 27.7 fps, 2, 79 ms | PASS |
| Kill cmux-mobile-host, WebRTC only | 22 | `track`, 32 to 48 fps | 1 | none | `track` (1153), 63 / 113 ms, 27.0 fps, 1, 70 ms | PASS |
| Switch to hybrid (from WebRTC) | 20 | `track`, 36 to 43 fps | 1 | none | `track` (1127), 60 / 79 ms, 31.7 fps, 0, 92 ms | PASS |
| Switch to WireGuard only (from WebRTC) | 23 | `wg-rtp`, 31 to 44 fps | 1 | none | `wg-rtp` (968), 66 / 164 ms, 29.6 fps, 3, 107 ms | PASS |
| Switch to WebRTC only (from WireGuard) | 22 | `track`, 31 to 47 fps | 1 | none | `track` (1102), 71 / 108 ms, 33.1 fps, 0, 73 ms | PASS |

The overlay's carrier label is missing in some OCR samples (the page
scrolls under it); every label read was the expected carrier. Workspace A's
tab was never opened again after the event (hostd saw one open: B's).

Before the fix (transport-verify-20261019.md, t-switch and t-kill): the tab
came back on `channel` at 1 to 4 fps and stayed frozen; hostd saw 3 to 5
`browser` opens after the event, the lane on a hidden tab, and the host
limit stopping the shown tab's host.

Terminal rows (the phone shows the seeded terminal; then a command typed on
the phone must reach the Mac's terminal):

| Row | What happened | Result |
| --- | --- | --- |
| Mac app quit and started again (daemon kept) | link back in about 30 s (graceful quit); "Reattaching…" cleared 0.3 s after; typed `echo` reached the same terminal | PASS |
| Mac app killed (daemon kept) | back in 1.4 s; the daemon answered `terminal_not_found` three times in 2 s, the reattach retried and attached; typed `echo` reached it | PASS (before the retry fix this row ended the live terminal) |
| Mac app and its daemon killed (new daemon, pid changed, surfaces renumbered 269 to 394) | back in 2.1 s; the UI's tab became `s394` and attached; typed `echo` reached the same terminal (`term_cfa558…`); no `[unknown surface]` on screen | PASS |

Not covered live: the label (defect 4) was checked by unit test only; a real
phone and a cellular path; WebRTC + Block UDP.

