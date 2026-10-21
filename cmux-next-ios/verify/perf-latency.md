# Cold launch and tab switch latency (2026-10-14)

Branch `feat-cnx-ios-perf`. The E2E rig (`verify/e2e`, run 005437-ios26) reported
cold launch to a settled Workspaces list at 4.2 s median (p95 4.5 s) and tab switch at
1.17 s median. Targets: 1.5 s (p95 2.5 s) and 150 ms.

## Rig

- Phone: one headless iPhone 17 Pro simulator `cmux-mobile-perf-ios26` (iOS 26.5), Demo build, deleted after.
- Mac: the real cmux-next DEBUG build `cmux-mobile-e2e-604fc689` (hidden, isolated rig config).
- Run: `run.sh --steps fresh_install,sign_in,choose_space,mac_discovered --latency tab_switch,cold_connect_to_list --samples 20`.
- `mac_discovered` fails on both builds since origin's Mac name disambiguation
  (`Aziz's MacBook Pro (1952)`); the rig looks for the bare name. The link was connected
  (live rows). That is a rig fix for later; it does not affect the latency steps.

## Most of the reported time was the rig

- **Cold launch.** The settle window ended 1 s before the next launch's host time. Under
  load, `simctl launch` takes long enough that this point fell after the next terminate.
  The home screen became the "final look", so the metric read the gap between launches.
  The video of 005437 shows the cached rows about 0.6 s after the launch animation, and
  the live rows about 1.5 s after it.
- **Tab switch.** t0 was the host time before `axe tap`, which takes 0.4 to 0.7 s to
  deliver the touch. The window could also end after the grid reopened.
- **Fix** (`latency.py`):
  - t0 is the app's own mark: process start for cold launch, and a new `tab_activate`
    event for tab switch. Both are streamed from the simulator log
    (`DeviceLog`, same clock as the video).
  - Windows end at the rig's next action.
  - The cold settle waits for the dimmed cached rows to turn live. It uses a low threshold
    and is never earlier than `workspace_row_live`.
  - New metrics: `cold_app_live`, `cold_app_cached`, `cold_launch_return`,
    `tab_switch_first_frame`, `tab_switch_host` (the old definition), `load_1min` and
    `raw_ms`.

## Results (n = 20 each)

Before is `f4eab78` (origin `86e11141` plus the rig fix). After is `da8a3c3`. Both used
the same rig and the same Mac build.

| Metric | Before median / p95 | After median / p95 |
| --- | --- | --- |
| Process start to settled live list, video (`cold_connect_to_list`) | 1578 / 2148 ms | 1549 / 2081 ms |
| Process start to the first live row, app mark (`cold_app_live`) | 1376 / 1979 ms | 1333 / 1912 ms |
| Process start to the first cached row (`cold_app_cached`) | 778 / 861 ms | 930 / 1245 ms |
| Process start to the Mac logging link up (`cold_link_up`) | 1220 / 1912 ms | **830 / 1082 ms** |
| Touch to the page settled (`tab_switch`) | 344 / 444 ms | 344 / 360 ms |
| Touch to the first changed frame (`tab_switch_first_frame`) | 105 / 111 ms | 106 / 113 ms |
| Host tap call to the page settled (old definition) | 704 / 773 ms | 698 / 731 ms |

Load (1-minute average): cold launch 12.8 before and 21.5 after; tab switch 5.1 before
and 18.7 after.

Old rig, run 005437: cold launch 4213 / 4456 ms, tab switch 1173 / 1279 ms.

## Cold launch: where the time goes

From the app's `timing` marks, in ms from process start, typical after values:

1. Before the app runs, 0 to 450 ms:
   - `dyld` takes about 250 ms (Time Profiler, simulator).
   - Then app init: `coordinator_start` at 455 and `snapshot_restored` at 457.
2. The link, 460 to 900 ms:
   - `dial_start` at 462 and `token_ready` at 462. Before this change, `token_ready`
     came 360 to 490 ms later.
   - `link_connected` at 670 to 920.
3. On the main actor, 800 to 1450 ms:
   - `workspace_row_cached` at 760 to 970.
   - `link_adopted` at 820 to 1050.
   - `link_served` 130 to 200 ms later.
   - `pairing_opened` 30 to 90 ms after that.
   - `daemon_channel_open` 40 to 110 ms after that.
   - `workspace_row_live` at 1065 to 1460.

Root causes found and fixed:

1. **The first dial waited for the main actor twice.** The dial `Task` started on the main
   actor, and the token came from `CmuxMobileAuthModel` (main actor). Both waited for the first
   frames to finish drawing.
   - Fix: the token is read without the main actor
     (`CmuxMobileAuthModel.serviceAccessToken`), and the token and dial run detached
     (`LinkController.connect`). Only adopting the link needs the main actor.
   - Prewarming runs detached as well.
2. **Stack's token read refreshes over the network** whenever the stored token was issued
   more than 75 s ago, even though the token stays valid for an hour.
   - Fix: a stored token valid for at least 60 more seconds is used at once
     (`AccessTokenExpiry`). Stack's refresh still runs in the background, and a 401
     still forces a new token.
   - The service accepts any unexpired token, so this shows nothing that is not true.
3. **The cached list was replaced, not reconciled.**
   - `AppStore.replaceWorkspaces` moved the Mac's rows behind every other Mac's rows (an
     animated reorder). It now replaces them in place (`AppStore.reconciled`).
   - The first live list dropped the snapshot's known activity times, so rows resorted as
     "no activity seen yet". `WorkspaceSync.bind(cached:)` now keeps them.

Checked and not the cause:

- Daemon requests are already one batched write. The first reply comes 5 to 10 ms after
  the channel opens.
- Discovery does not wait on all Macs or teams. The snapshot path dials before the
  bootstrap answers, which comes at 1.2 to 1.6 s.
- No per-workspace agent fetch happens; `list-agents` is in the batch.

Left:

- The link is up by about 0.8 s, but the live row still waits behind main-actor work:
  SwiftUI's first layout passes of the shell (Time Profiler: `_UIHostingView.layoutSubviews`
  and AttributeGraph, with `WorkspacesList.sameNames` and `filterMenu` the largest app
  frames).
- Between link up and the live row there are four main-actor hops (`adopt`, the state
  watch, `serve`, `bindWorkspaces`). Opening `auth` and `daemon` in one detached step
  after the dial would remove most of them.

## Tab switch

- Previously visited terminal tabs were already kept warm, and switching between them does
  no reattach or round trip. The touch reaches the first changed frame in about 105 ms.
- The page settles about 240 ms later. That is TabsKit's card-to-page zoom spring
  (`ZoomSpring.toPage`, fitted to Safari), which this app cannot change: CmuxTabsKit must
  stay byte-identical with its upstream.
- Reaching 150 ms to settled needs a shorter zoom in CmuxTabsKit. That is a visual design
  decision (#13742).
- Fixed: warm tabs were unbounded.
  - `GhosttyTerminalTabContent` now keeps the 4 most recently shown terminal tabs warm
    (`TerminalWarmSet`).
  - An older tab is cooled: its attach is closed (`DaemonTerminalSession.stop` now closes
    its channel) and its surface is released.
  - When a cooled tab is shown again, it shows its last frame at once, dimmed under the
    connecting label (`TerminalModel.coldFrame`), while it reattaches in the background.
- Runtime check, not a rig metric: 6 terminal tabs, visiting t1 to t6 and back to t1.
  - Logs: `terminal tab s58 cooled (warm set of 4), last frame kept`.
  - t1 showed its content at 0.15 s and had no connecting overlay after 2.5 s.

## Tests

- `swift test` on `mini-cmuxs-mac-mini-2` (Xcode 26.3): 306 tests in 97 suites pass.
  - New: `LaunchReconcileTests` (in-place reconcile, token expiry).
  - New: `LaunchReconcileLiveTests` (the first live list keeps cached activity times).
  - New: `TerminalWarmSetTests`.
- The iOS simulator Demo and Production builds compile.

## Round 2: channels in the dial step, memoized Mac text (2026-10-14)

Before is `d494906d` (round 1 merged). After is `77f74ea0`. Both used the same rig (`30a3f0c2`
plus `sim.py` failing loudly when a recording does not start), the same Mac build and
simulator, `--max-load 25`, n = 20 each.

| Metric | Before median / p95 | After median / p95 |
| --- | --- | --- |
| Process start to settled live list (video) | 1256 / 1383 ms | **1141 / 1232 ms** |
| First live row (app mark) | 1048 / 1135 ms | **950 / 970 ms** |
| First cached row (app mark) | 771 / 799 ms | 766 / 784 ms |
| Link up (Mac log) | 705 / 805 ms | 687 / 739 ms |
| Tab switch, touch to settled | 344 / 360 ms | 346 / 360 ms |
| Tab switch, touch to first frame | 107 / 112 ms | 109 / 113 ms |

Load (1-minute average, median of the samples): cold launch 11.9 before and 11.0 after;
tab switch 10.9 before and 16.5 after.

Marks (median of 12 logged launches, ms from process start):

| Mark | Before | After |
| --- | --- | --- |
| `link_connected` | 692 | 688 |
| `pairing_opened`, `daemon_channel_open` | 990, 1030 | 689, 689 (in the dial step) |
| `first_daemon_response` | 1042 | 690 |
| `link_adopted` | 832 | 828 |
| `link_served` | 960 | 833 |
| `workspace_row_live` | 1052 | 950 |

What changed:

- **Dial step opens the channels.** `LinkController.prepare` runs in the dial's detached
  step. It opens `auth`, then `daemon` (the order a pairing Mac needs), and sends the
  setup batch (`WorkspaceSync.prepare`).
- **No wait for the state stream.** A link that knows its path (`MacLink.connectedPath`)
  is adopted as connected in the same turn.
- **Served in the adoption turn.** The coordinator serves a prepared link in that turn
  (`startServing`), and pairing's challenge starts detached (`startPairing`).
- **Hops removed.** Link-up to live row went from about seven main-actor hops to two.
  The remaining wait is for the main actor itself: `link_adopted` is about 60 ms after the
  first cached frame.
- **Mac text memoized.** `MacFilterMemo` computes the Mac names' disambiguation and the
  Filter rows once per change, not on every body pass. The first cached row did not move
  measurably on this account (22 Macs).

Cached-row regression in round 1 (930 vs 778 ms): not reproduced at matched load (766 vs
771 ms). The round-1 after run ran at load 21.5, the before run at 12.8.

Rig:

- `--max-load N` waits before each sample.
- `mac_discovered` passes again. It finds the rig Mac's Filter row by device id, and reads
  its subtitle after the menu settles; the OCR read too early saw only the title.
- A recording that does not start now fails the metric instead of reporting n = 0. A
  killed recorder leaves "Host recording is already in progress" until the simulator
  reboots.

Tests: `PreparedLinkTests` and `MacFilterMemoTests`. `swift test` on
`mini-cmuxs-mac-mini-2` (Xcode 26.3): 312 tests in 99 suites pass. The tests use new APIs,
so they could not be committed failing ahead of the fix.
