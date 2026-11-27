# iPhone app loading placeholders: inventory

Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all these placeholders doen and prevent them".
Also (ask-6e4dab7cf1): "the loading has layout shifts and placeholder states that likely dont need to be so placeholder and better diffed".

The rule: a screen the phone has seen before draws what it last had (cached rows, the last transcript, the last frame) and updates in place.
It does not draw a spinner, a skeleton or a "Loading…" line while it waits for the Mac. A placeholder is fine only when nothing has ever been cached (first sign-in, first pairing) or for a wait the person started (a send, a download).

## What stops new ones

`scripts/ci/check-ios-loading-placeholders.py` runs in `ci-guards.yml` preflight on every PR. It fails a change that adds a spinner (`ProgressView`, `CmuxSpinner`), a skeleton, `.redacted(reason: .placeholder)` or loading copy ("Loading chats…", "Connecting…") to `cmux-next-ios/` or `Packages/iOS/` Swift.
A real wait keeps its indicator with `placeholder-ok: <why nothing cached can stand in>` on the line or the two lines above it.
`--scan` lists every existing hit: 139 on 2026-11-24 (88 spinners, 47 loading lines, 4 skeletons).

## Load and switch placeholders to replace (2026-11-24 sweep)

"Owner" is the open PR that removes the placeholder, or the lane that took it. Each fix keeps the placeholder only for the never-loaded case.

### Workspace list

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/WorkspacesList.swift:378` | showsSkeleton predicate: firstLoad or Mac lists loading | #53810 (WorkspacesLaunchState, partial); #53960 probe only; 54109/54360 cheaper delta only | draw persisted last workspace rows per Mac; skeleton only on never-signed-in install |
| `CmuxMobileWorkspaces/WorkspacesList.swift:389` | skeleton overlay captioned 'Loading workspaces…' / 'Waiting for a connection…' | same as `:378` | same as `:378` |
| `CmuxMobileWorkspaces/WorkspacesList.swift:422` | SkeletonList(6 rows) full-screen view | same as `:378` | same as `:378` |
| `CmuxMobileWorkspaces/WorkspacesList.swift:608` | 'loading' entry: skeleton under Mac lines while inbox loads | #53810 partial; #53960 probe | kept rows of that Mac stand in; no skeleton when any cached rows |
| `CmuxMobileWorkspaces/WorkspacesList.swift:645` | SkeletonList(4 rows) cell for that entry | #53810 partial; #53960 probe | same as `:608` |

### workspace list status

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/ListStatusRow.swift:28` | 'Updating…' label of the list status row | #53810 | remove (covered) |
| `CmuxMobileWorkspaces/ListStatusRow.swift:59` | 'Updating…' sentence in chip over rows | #53810 | remove (covered) |

### chat transcript

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileAgentChat/AgentChatStore.swift:1928` | loadingText 'Connecting to Mac' when no turns drawn and link down >10s | #53904 | draw cached turns; text only for a chat never opened here |
| `CmuxMobileAgentChat/AgentChatStore.swift:1930` | loadingText: starting text or 'Loading chat…' while no turns | #53904 (kept chat first frame); #53810 gates Connecting | draw cached turns at once; words only for a chat never seen |

### chat (cold open)

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileAgentChat/AgentSessionDirectory.swift:177` | spinner + 'Loading chat…' while workspaces load (notification cold open) | none (53910 adjacent) | resolve tab from persisted workspaces/last-place and draw its cached turns |

### chat replay

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileAgentChat/ChatPolishScreens.swift:352` | spinner 'Loading this chat's history…' before records load | none | draw the cached transcript statically while recorded history loads |

### chat tool card

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileAgentChat/ToolViews.swift:135` | 'Loading the full output…' on expanding a truncated tool call | none | keep the truncated output visible, swap full text in place at same height |

### Agent chats list

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/AgentChatsScreen.swift:299` | spinner 'Loading chats…' when chats empty on open | #53810 (removes Updating only) | persist last chats list per Mac; seed model from it so phase is never .loading with a cache |

### Panes

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/PanesScreen.swift:105` | spinner 'Loading panes from Mac…' until Mac list arrives | none | persist last panes/layout per workspace; draw it |

### Screens

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/ScreensPage.swift:80` | spinner 'Loading screens from Mac…' until list arrives | none | persist last screens per workspace; draw it |

### New task / agent chooser

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/AgentChooser.swift:50` | spinner 'Loading agents…' | none | draw last-known agents list |

### Task composer

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileWorkspaces/TaskComposerScreen.swift:365` | disabled 'Loading agents…' menu button | none | reuse last agents list |

### Cloud automations

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileChief/CloudAutomationsScreen.swift:32` | spinner 'Loading automations…' on every open | none | persist last automations; draw them, refresh in place |

### Cloud chats

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileShell/CloudChatsScreen.swift:50` | spinner 'Loading Cloud chats…' on open | none | persist/draw last Cloud chats per machine |
| `CmuxMobileShell/CloudChatsScreen.swift:169` | spinner 'Connecting to machine through Mac…' with counter | none | draw last Cloud chats; keep connect wait as quiet line past 5 s |

### Cloud machines

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileChief/CloudMachinesScreen.swift:44` | spinner 'Loading Cloud machines…' on every open | none | persist last machines; draw them, refresh in place |

### Conversations home

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileChief/ConversationsHome.swift:410` | 'Loading conversations…' note while rows load | #53810 (partial: Updating/Connecting only) | draw kept conversation rows; note only with none ever seen |

### Feed

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileFeed/FeedScreen.swift:344` | spinner 'Connecting to your Mac…' when no events known | none | persist last feed events and draw them; spinner only if never seen |

### Mac screen view

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileScreenSharing/MacScreenRdView.swift:38` | 'Connecting to Mac…' label over the RD stream every open | none | draw last frame of that Mac's screen; label after quiet gate |

### Screen sharing page

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileScreenSharing/ScreenSharingPage.swift:308` | card 'Connecting to host…' EmptyState every open | none | show last frame of that Mac's screen under a quiet line |

### Settings > Devices

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileSettings/DevicesPage.swift:95` | 'Loading…' when macs empty before first load | none | draw persisted Mac roster; no text |

### Settings > members

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileSettings/SettingsPages.swift:255` | 'Loading members' row on open | none | draw last-known team members, refresh in place |

### Settings > terminal sizing

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileSettings/TerminalSizingPages.swift:114` | 'Loading Macs…' while account data awaits | none | draw persisted Mac roster (shared with Devices) |

### Team sidebar

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileShell/TeamSidebar.swift:37` | spinner 'Loading teams…' when teams empty | none | persist teams list; draw it |

### browser page

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxMobileBrowserStream/StreamedBrowserPage.swift:72` | 'Loading browser session…' over blank stream | none | draw last streamed frame of that page; text only for first-ever open |

### iOS conversation header

| Where | Shows | Owner | Stand-in |
|---|---|---|---|
| `CmuxConversationUI/ConversationViewController.swift:439` | 'Connecting' header status while link down | none | gate after quiet 10 s like AgentChat; rows stay |

## Kept on purpose

21 hits are real waits with nothing to cache: first sign-in and pairing, billing purchases, voice and call setup, the terminal's skeleton when no frame was ever cached, and older-page loading in a conversation. Each gets a `placeholder-ok:` reason when it is next edited.
The other spinners are mostly in-flight actions the person started (send, connect, retry buttons).

## Proof

Done when the screens in Leo's 2026-11-24 13:13 photos load with no placeholder frame on a real-device recording (`cmux-next-ios/scripts/try.sh PR` on the phone, screen-recorded from launch and from a workspace switch).
