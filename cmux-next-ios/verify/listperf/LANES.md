# Smooth lists: fix lanes (shared brief)

Goal: every vertical list in the cmux-next iOS app (`cmux-next-ios/`) scrolls at full frame rate,
idle and while live data changes (agents streaming, a busy Mac). Performance is the focus. Visual
design and behavior stay as they are unless a change is needed for speed; never drop a feature.

## The bar (60 Hz simulator, measured with the rig, before and after)

- Scrolling, idle and live: hitch time under 5 ms/s, no frame over 33 ms in steady state,
  main-thread CPU per frame p99 under 8 ms.
- Opening a screen (`*-open` window): no frame over 100 ms; under 33 ms is the target.
- Cost is O(visible rows) per frame and O(changed rows) per update, never O(all rows).
- Memory stays bounded by what is on screen (log lines `list-stress memory ... footprint=`).

The reference implementation is the Feed (`CmuxMobileFeed/FeedCollection.swift`, `FeedListLayout.swift`,
`FeedRowLayout.swift`, `verify/feed-perf-20261023.md`) and the Chief transcript in
`Packages/iOS/CmuxConversation` (`ConversationViewController`, `ConversationTranscriptLayout`): UICollectionView,
diffable data source keyed by stable string ids, `reconfigureItems` for changed rows, layouts or heights computed
once per content key (off main where it is heavy), cells reused, no SwiftUI tree per whole list.

## Architecture decisions (already made; do not re-litigate)

- Long or live lists (agent transcript, diff, artifacts grid, tabs grid if needed) are UIKit
  `UICollectionView` with a diffable data source of string ids. Row content may stay SwiftUI inside cells via
  `UIHostingConfiguration` where the row is cheap, but row heights are cached per (id, content revision, width)
  and the list never hosts one SwiftUI view for all rows.
- Short, mostly static lists (Workspaces, Home, settings) stay SwiftUI `List`: fix invalidation instead
  (row views with plain value inputs that SwiftUI can skip, derived data memoized once per change, menus built
  on demand, no per-frame `TimelineView` in rows, stable section and row identity).
- Live data reaches a list coalesced to at most one apply per frame, and only for rows that changed.
  Streaming text appends coalesce per frame; derived values (`turn.rows`, `changeSet`, diffs, markdown parses)
  are memoized by content revision and never recomputed in a body per token.
- Heavy work (diffing, markdown parse, syntax highlight, text measurement, image decode, thumbnails) runs off
  the main thread or once per content key, never in `body` per frame.

## The rig

`cmux-next-ios/verify/listperf/rig.sh` (read its header). `ListStressRig` (CmuxMobileShell) seeds a screen in mock
mode and scrolls it; `matrix.sh` holds the cases. Each lane has its own host, DIR and SIM_NAME (below). Once per lane:

    export HOST=<host> DIR=<dir> SIM_NAME=<sim>
    cmux-next-ios/verify/listperf/rig.sh sync && cmux-next-ios/verify/listperf/rig.sh seed-xcf && cmux-next-ios/verify/listperf/rig.sh sim

Then per iteration: `rig.sh sync && rig.sh build && rig.sh run LABEL SCREEN K=V..` (`SAMPLE=25` for a 1 ms
`sample` profile from launch; `VIDEO=1` for a recording). Evidence lands in `cmux-next-ios/verify/evidence/listperf/`.
Run the base (your worktree's first commit) before changing anything, then your head, same host, alternating, 2 reps.
`ListStressRig` may be extended (a new screen, a live mode); keep it DEBUG-only.

## Rules

- Never build, test or run Swift on this laptop (no `swift build`, `swift test`, `xcodebuild`). Builds and simulators run
  only on the lane's fleet host through the rig. Minis are shared CI runners: one build at a time, `-jobs 6` as the rig sets.
  Unit tests: `ssh <host> 'cd <dir>/cmux-next-ios/CmuxMobileKit && DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer swift test --filter <Suite>'`
  (AWS hosts: `/Applications/Tailscale.app/Contents/MacOS/Tailscale ssh ec2-user@<host> ...`).
- Never use `osascript`, never open Simulator.app, never take focus on this Mac. Simulators are headless (`simctl`).
- No sleeps as synchronization in product code; DEBUG rig pauses are fine.
- Do not edit `Packages/iOS/CmuxConversation`. `Packages/iOS/CmuxTabsKit` may change only in the tabs lane, which
  must keep it usable standalone (its public API and `TabsKitDemo` host).
- Add a regression test for each fix where a unit test can catch it (memoization counts, identity stability,
  O(changed) applies), committed red first when practical; run it on the fleet host.
- Commit in your worktree with clear messages ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  Do not push and do not open PRs; the coordinator integrates.
- Run `python3 scripts/cmux-next/prepush-gate.py` from your worktree before your final commit and fix what your commits add.
- Final reply: what changed (files), the before/after table from the rig (label, hitch ms/s, max frame, main CPU ms/s,
  open window max, memory), the evidence file names, tests run with results, and anything not done and why.
