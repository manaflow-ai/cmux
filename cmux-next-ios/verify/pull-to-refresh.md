# Pull to refresh under the pull-down search

The Workspaces list has the pull-down search drawer (`cmuxMobilePullDownSearch`: the native
navigation-bar drawer, tucked under an inline title on launch) and pull to refresh. Reported
2026-11-13 from an iPhone on iOS 27.2: the pull looked distorted, "fighting with the search bar".

## What UIKit did

Measured per frame with the list rig's pull trace (below) on the iPhone 17 Pro Max simulator,
iOS 27.0, with the app built by Xcode 27.0 and by Xcode 26.6 (the same in both):

| Moment | Search field (window y) | Refresh control | List offset |
| --- | --- | --- | --- |
| Pulling | stays at 116 while the bar stretches below it | inside `UIKitNavigationBar`, frame 116 to 176: behind the field | follows the finger |
| Refresh starts | jumps to 176 in one frame | still 116 to 176, now visible above the field | continuous |
| Refresh ends | jumps back to 116 in one frame | | jumps 60 pt up the next frame, then the drawer sometimes collapses over the first row |

When a list is its screen's content scroll view and the search drawer can collapse
(`hidesSearchBarWhenScrolling`, the drawer's `.automatic` mode), UIKit moves the list's
`UIRefreshControl` into the navigation bar, between the title and the drawer. That layout
works with a large title (the title and the field move down with the pull). With an inline
title the drawer stays pinned, so the control is drawn behind the field until the refresh
starts and the bar makes room for it in one frame.

Variants tried on the same rig:

| Variant | Refresh control lives in | Result |
| --- | --- | --- |
| `UIRefreshControl` added as a plain subview | the navigation bar | same jumps |
| list not registered as the content scroll view | the list | smooth, but the drawer no longer collapses or tucks |
| drawer always shown (`.always`) | the list | smooth, but no tucked search |
| large title | the navigation bar | smooth (title and field move with the pull), a different page design |
| switching `hidesSearchBarWhenScrolling` off at the top | the navigation bar | no change |

## The fix

`ListPullToRefresh` (CmuxMobileDesign) replaces `UIRefreshControl` on the Workspaces list. It
keeps its wheel in the list, under the search field, with the numbers UIKit's control uses when
it stays in a list (the always-shown drawer variant): 8 ticks, 30 pt across, that fill in
clockwise as the list is pulled; a refresh at 186 pt of pull; a 60 pt slot held under the field
while it runs; then the slot closes and the wheel shrinks away. The slot opens when the finger
lifts: changing the inset under a finger restarts UIKit's rubber band from the new top, and the
rows jump. It closes frame by frame on the theme's smooth spring with the list held at its top:
removing it at once lets UIKit clamp the offset in one frame, and scrolling the rows up over it
reads to the navigation bar as scrolling into the list, which collapses the search drawer
(measured: the drawer shrank from 54 to 0 pt, then the rows jumped 54 pt). VoiceOver's
three-finger scroll at the top still refreshes.

## Rig

The list rig (`verify/listperf/rig.sh`, `ListStressRig`) with two settings:

- `CMUX_MOBILE_LIST_REFRESH_SECONDS=S`: the mock Workspaces list gets a refresh lasting S seconds.
- `CMUX_MOBILE_LIST_PULL_TRACE=1` (with `CMUX_MOBILE_LIST_PASSES=0`): one `PULL` line per frame that
  changes (category `frames`): the list's offset and top inset, whether a finger holds it, the
  wheel's centre and height, and the search field's top and height, in window points.

```bash
HOST=aws-m4pro-2 DIR=ptr verify/listperf/rig.sh sync      # aws-m4pro-2 has the iOS 27 simulator and AXe
# build (Xcode 27.0 there; Xcode 26.6 needs a host with the iOS 26.5 runtime, such as aws-m4pro-6)
SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=workspaces SIMCTL_CHILD_CMUX_MOBILE_LIST_PASSES=0 \
SIMCTL_CHILD_CMUX_MOBILE_LIST_REFRESH_SECONDS=1.2 SIMCTL_CHILD_CMUX_MOBILE_LIST_PULL_TRACE=1 \
  xcrun simctl launch "$UDID" "$BUNDLE" -cmuxMobile.setupComplete YES -cmux-mobile-no-restore
axe swipe --start-x 220 --start-y 300 --end-x 220 --end-y 420 --duration 0.5 --udid "$UDID"   # reveal the field
axe swipe --start-x 220 --start-y 260 --end-x 220 --end-y 700 --duration 1.4 --udid "$UDID"   # pull to refresh
xcrun simctl spawn "$UDID" log show --last 1m --info --predicate 'category == "frames"' | grep PULL
```

Pass: `search=` never changes during a pull or a refresh, the wheel's centre is below the field
(field top + field height + 30 while refreshing), and the offset changes by no more than a
frame's worth of motion at the refresh's start and end.

The regression test is `WorkspacesPullToRefreshTests` (CmuxMobileWorkspacesTests): in a
navigation controller with an inline title and a collapsible search drawer, the list's refresh
UI is in the list and none of it is in the navigation bar.
