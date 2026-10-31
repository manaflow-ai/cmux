# Workspaces list: design loop

Branch `feat-cnx-ios-wsdesign`, 2026-10-13. Designer round 1. Screenshots are
git-ignored, in `verify/evidence/2026-10-13/wsdesign/directions/`.
Prototypes are DEBUG-only, in `CmuxMobileKit/Sources/CmuxMobileWorkspaces/Prototypes/`,
and are shown in the real Workspaces tab with `-cmux-mobile-wsproto A|B|C`
(optionally `-cmux-mobile-wsproto-mac <macID>` to start filtered; the IDs are
`studio` and `mbp`).

## Diagnosis

What the user does on this screen, in order of frequency:

1. **Find what needs me.** An agent is blocked on a permission or a
   question. This is why the user opens the app from a pocket. The tab badge
   already counts it, so the list has to show which workspaces they are and
   why.
2. **Check what is running.** Is Codex still working on the pricing page? Did
   Claude finish?
3. **Get back to where I was.** Open a workspace and land on its last tab.
4. **Know where it lives.** Which Mac, and is that Mac awake? This matters
   only when the user has more than one Mac, or one Mac is offline.

A workspace is a long-lived place: a directory, a branch and a set of tabs.
There are about 5 to 20 of them. It is not a disposable chat, and it is not a
dashboard record.

### Design 1 (title menu, sticky per-Mac headers, three-line rows): a dashboard dump

- **Wrong primary grouping.** The sticky per-Mac section headers made the Mac
  the top of the hierarchy. The user thinks "what needs me", not "what is on
  the Mac Studio". A blocked agent on the second Mac sat below every row of the
  first Mac.
- **Status buried.** "Needs you" was on line 3, after the branch line and the
  tab-kind glyph counts. The most important fact was the last thing read.
- **Every fact had the same weight.** A mono branch with a glyph, the tab
  kinds as glyphs with counts (`sparkle 1 apple.terminal 1 globe 1`) and a
  status subtitle came to about 80 pt per row, with about 7 rows per screen.
  Tab-kind counts are inventory, not information. Nobody decides what to open
  from "1 agent, 1 terminal".
- **Hidden and configurable.** The filter was hidden in the title ("All Macs
  ⌄"), and a More menu offered Sort and Show Offline Macs. That is settings
  work the user should never have to do on a phone.
- **Offline rows looked like normal rows** but were dead links that read
  "Unavailable while offline".

### Design 2 (current: Mac chips, Today/Yesterday sections, one-line names): a chat history

- **It copied the wrong object.** ChatGPT's sidebar indexes hundreds of
  throwaway chats, so recency buckets help there. With 10 long-lived
  workspaces, the buckets split the list into headers with one or two rows
  each: more chrome than content. In live mode they also lie. The daemon
  reports no activity time, so `DaemonTree` stamps first sight and every row
  sits under "Today".
- **It is a navigation drawer pattern on a root tab.** A sidebar is sparse on
  purpose because it sits next to content. As a full-screen tab root, the
  one-line names look unfinished and leave most of the screen empty.
- **Names alone do not identify.** Workspace names repeat ("cmux" on two Macs,
  "Workspace") and say nothing about state. The branch, the Mac and the agent's
  task were all removed.
- **The status was an unexplained 7 pt dot.** A yellow dot (needs you) and a
  breathing white dot (working) cannot be told apart at a glance, there is no
  word for either, and "done" was not shown at all. The user's most important
  question went from buried (design 1) to cryptic (design 2).
- **The chips cost 50 pt for a rare action.** Most users have one or two Macs
  and seldom filter. A single-Mac user sees "All · Mac Studio", which is noise.
  Offline workspaces were dimmed rows mixed into the time sections, still dead
  on tap.

### The common failure

Neither design ordered the list by the user's first question. Design 1 showed
everything and design 2 showed nothing, and both put status in the wrong
place. The fix is not density but **priority**: what needs you first, in
words, then what is running, then everything else. The Mac is metadata
unless it is offline.

## Research

| Source | Pattern | Taken |
| --- | --- | --- |
| Apple Mail / Messages (iOS 26) | Two-line rows: a bold name with a trailing `footnote` time, then a secondary line. An unread dot in a leading gutter. Separators inset to the text. Swipe trailing for destructive actions. | Row anatomy, the leading status gutter, the time position. |
| Archived iOS HIG, Tables ([codershigh mirror](https://codershigh.github.io/guidelines/ios/human-interface-guidelines/ui-views/tables/index.html)) | The subtitle style "works well in a table where rows are visually similar; the subtitle helps distinguish rows". | Two lines, not one: workspace names are similar. |
| T3 Code sidebar v2 concepts ([postplan.dev](https://hsyscdqldmk5.postplan.dev/)) | Status priority: Pending Approval > Awaiting Input > Plan Ready > Working > Done·unseen > Failed > Idle. "Attention tiers": the needs-you tier pinned at the top, so actionable items cannot scroll away. "Adaptive density": active threads are rich, settled ones one line. A recency list with the project demoted to metadata, "never a group header". | The priority order, pinning needs-you, project/Mac as metadata (A); adaptive density (C). |
| [Cursor on web and mobile](https://cursor.com/blog/agent-web), [docs](https://cursor.com/docs/cloud-agent) | One list of agents for monitoring progress and reviewing results from a phone. | Status per row as text. |
| Codex in ChatGPT iOS ([Verdent guide](https://www.verdent.ai/guides/codex-in-chatgpt-mobile), [changelog](https://learn.chatgpt.com/docs/changelog)); captures `chatgpt-07-codex-title-menu`, `chatgpt-12-codex-search` | "See what's currently running and which ones have finished"; open a completed task from a notification straight into its review. The title menu sorts Priority / By project / Chronological. | Opening a waiting workspace goes to the waiting tab, not the last tab. Priority as the default order. |
| Claude Code on mobile ([docs](https://code.claude.com/docs/en/mobile)) | Sessions in the Code tab; a push notification when a task "finishes or needs a decision from you". `claude-01-sidebar`: title with a secondary "yesterday" line. | "Needs you" and "Done" are the two notification-worthy states. |
| GitHub Mobile inbox ([discussion](https://github.com/orgs/community/discussions/168685)) | Filters Participating / Unread / All, swipe to Done. | A filter is a menu, not a permanent row. |
| `chatgpt-38-search-results` | Search results as two-line rows with the match in the second line. | Search keeps the same row. |
| Files "Locations", Find My, Settings | Inset-grouped cards per place with a presence header. | Direction B. |

## Directions

Data in all three: two Macs (Mac Studio online, MacBook Pro offline, last
seen 2h ago) and 10 workspaces with mixed states, built on the real
`Workspace` / `MacDevice` / `WorkspaceTab` types (`ProtoData.swift`).

### A: Inbox (Mail anatomy, attention pinned)

`ProtoInbox.swift`, `-cmux-mobile-wsproto A`.

- Inline title "Workspaces" with a `navigationSubtitle`: "2 need you", or the
  filtered Mac and its presence.
- Sections are scrolling rows, not pinned: **Needs You** (only when not
  empty), **Recent** (online, newest first), then one folded line per offline
  Mac ("MacBook Pro · Last seen 2h ago · 3 ›") that expands in place.
- Two-line rows: the name (semibold) and its time; then the status sentence:
  "**Claude is waiting** · Refactor transport layer", "Codex is working ·
  Fix pricing page layout" (shimmer), "**Done** · Claude: Audit runner
  labels", or the branch/directory when idle. A leading 32 pt gutter holds a
  yellow disc, a mini spinner or a dot.
- The Mac filter is a toolbar menu next to New, filled when active.
- Long press: header "Mac Studio · feat-cnx-ios", then the workspace's tabs
  (jump straight to one), then Rename and Close Workspace.

Screens: `verify/evidence/2026-10-13/wsdesign/directions/A-dark.png`,
`A-light.png`, `A-offline-expanded.png`, `A-filtered-offline.png`,
`A-menu.png`, `A-dark-ax.png` (accessibility-large).

Why: it answers the four questions in their order on one screen with no
configuration. Ten workspaces fit with no scrolling. It is the most
familiar iOS list there is.

### B: Places (one inset-grouped card per Mac)

`ProtoByMac.swift`, `-cmux-mobile-wsproto B`.

- A card per Mac headed by its icon, name, presence dot and "Online" / "Last
  seen 2h ago". An offline Mac's card collapses to "3 workspaces · Show ⌄".
- Rows: the workspace's own cmux-next color and icon (or its initial) in a
  30 pt rounded square, the name, the branch, and a trailing status:
  "● Needs you" capsule, spinner + "Working", "✓ Done", else the time. Within
  a card, rows sort by status, then recency.
- No filter control: the grouping is the filter.

Screens: `B-dark.png`, `B-light.png`, `B-offline-expanded.png`.

Why: it is the strongest answer to "where does it live" and suits a fleet of
Macs. Against it: a blocked agent on the second Mac is still below the
first Mac's card, the same flaw as design 1 in a better coat. The colored
glyphs are colorful chrome that most workspaces (no color or icon set) would
show as gray initials.

### C: Now + Everything (adaptive density)

`ProtoNow.swift`, `-cmux-mobile-wsproto C`.

- **Active**: cards (`sheet` fill, radius 20) for needs-you, working and
  done workspaces: glyph, name, status tag; the agent's task in `label`; Mac ·
  branch · time. A needs-you card has a warning hairline.
- **All Workspaces**: one-line compact rows with the Mac name, offline ones
  last and dimmed.
- Mac filter in the toolbar, as in A.

Screens: `C-dark.png`, `C-light.png`, `C-light-scrolled.png`.

Why: the live work dominates, like a dashboard of agents. Against it: five
cards fill the screen, so the "get back to where I was" list starts below the
fold. Cards jump between the two sections as agents start and stop, which
breaks spatial memory. It is the busiest of the three.

## Choice

**A, with two ideas from C.** A is the only direction where the most
important fact is the first thing on screen, in words, and where the whole
list fits on one screen. It is plain native iOS (Mail anatomy, system menus,
system swipe, no custom cards), and it reads like the ChatGPT and Claude
lists the user likes, without copying a drawer.

From C: the status line names the agent and its task, and a tap on a
needs-you workspace opens the **waiting tab**, not the last tab. From B: no
generic icons on rows. The workspace color is not shown on rows (most
workspaces have none).

Rejected: B's per-Mac primary grouping (design 1's flaw), C's cards (visual
weight and jumping rows), chips and recency buckets (design 2).

## Spec

Replaces SPEC 11.1's list portion. File: `CmuxMobileWorkspaces/WorkspacesList.swift`.
Remove `MacChipRow`, `MacChip`, `RecencyHeader`, `RecencyBucket` usage and the
recency layout. Keep `NewWorkspaceButton`, `ConnectMacEmptyState`, the
rename/close flows and `PullDownSearch`.

### Layout

- `NavigationStack` root, `List` `.plain` on `bg`, `scrollContentBackground(.hidden)`,
  `listSectionSpacing(4)`, default soft scroll edge, tab bar minimizes on
  scroll (SPEC 3.2).
- Toolbar: leading the Teams circle (unchanged); inline title "Workspaces"
  (`screenTitle`); `.navigationSubtitle` (iOS 26):
  - filtered: "<Mac> · Online" / "<Mac> · Last seen 2h ago";
  - else if any needs you: "N need you";
  - else with 2+ Macs: "2 of 3 Macs online";
  - else none.
  Trailing glass capsule: Filter (only with 2+ Macs in the team) and New
  Workspace.
- Search: `.searchable` in the navigation bar drawer, tucked at launch
  (keep `PullDownSearch`). Matches name, branch, directory, Mac name and agent
  tab titles. Results keep the same rows and sections.
- Pull to refresh in live mode (unchanged).

### Sections and sorting

Section titles are list rows that scroll (not pinned headers: pinned plain
headers overlap rows under the glass bar). Title row: `meta` semibold,
`label2`, insets 14 top / 2 bottom / 20 sides, no separator, `.isHeader`.

1. **Needs You**: only when not empty. Online workspaces with
   `needsAttention`, longest waiting first (see data gaps; `lastActivityAt`
   descending until a wait-start time exists).
2. **Recent**: every other online workspace, `lastActivityAt` descending.
   Working and done rows stay in place by time; they do not jump to the top.
   Title omitted when Needs You is absent and there are no offline Macs.
3. **One folded line per offline Mac**, team order: `moon.zzz` + "<Mac> ·
   Last seen 2h ago", trailing count + `chevron.right` (rotates 90° when
   open), `meta` semibold `label2`. A tap expands its rows in place (`smooth`);
   the open state is per Mac, per session. When the filter is that Mac, the
   rows are always shown and the chevron hidden.

A workspace on an offline Mac never appears in Needs You or Recent. Its
agent state is stale.

### Row anatomy

- Insets: leading 0, trailing 20, vertical 10. Min height 60 (two lines at
  Large). `listRowBackground(bg)`. Separator 0.5 pt, leading aligned to the
  text at 32 pt (`alignmentGuide(.listRowSeparatorLeading)`).
- Leading status gutter, 32 pt wide, centered on line 1:
  - needs you: 10 pt `warning` disc;
  - working: `ProgressView().controlSize(.mini)`;
  - done: 8 pt `label` disc;
  - pending creation: mini spinner (as today);
  - idle or offline: empty.
- Line 1: name, `rowTitle` semibold, `label` (offline `label3`), 1 line;
  trailing time `meta` with `monospacedDigit`, `label2` (needs you: `label`),
  from `RelativeStamp.string` ("now", "4m", "3h", "2d").
- Line 2: `rowSubtitle`, `label2`, 1 line (2 at accessibility sizes):
  - needs you: "**<Agent> is waiting**" (`label`, semibold) + " · <agent tab title>";
  - working: "<Agent> is working" with the SPEC 4.5 shimmer, + " · <tab title>".
    Build it as **one** `Text` masked by the shimmer, not an `HStack` of two
    texts; the prototype's `HStack` truncates both halves at AX sizes
    (`A-dark-ax.png`);
  - done: "**Done**" (`label`, semibold) + " · <Agent>: <tab title>";
  - idle: the branch, else the directory; append " · <Mac>" only when the
    Recent section holds workspaces from 2+ Macs and no filter is set;
  - offline: as idle, at 60% opacity.
  `<Agent>` is the harness name ("Claude", "Codex"; else capitalized; else
  "Agent"). When no agent tab is known, use "Needs you" / "Working" / "Done"
  alone.
- Press: the system list highlight (no custom rounded fill).

### Status rules (priority, highest first)

| State | Derived from | Gutter | Line 2 word |
| --- | --- | --- | --- |
| Creating | `store.isPending(id)` | spinner | (the directory) |
| Offline | `mac.isOnline == false` | none | (where) |
| Needs you | `needsAttention` | warning disc | "<Agent> is waiting" |
| Working | `isWorking` | spinner | "<Agent> is working" |
| Done | `hasUnread` and not working | label dot | "Done" |
| Idle | otherwise | none | (where) |

"Done" clears when the user opens the workspace (the Mac clears
`unread_count` / `marked_unread`; if it does not reflect a phone open, clear
it locally on open and keep it cleared until the next unread change).

### Tap: what opens

- Needs you: push the workspace on the **waiting agent tab** (see data gaps).
- Otherwise: `store.openingTab(for:)` (the last tab used on this device, else
  the first). Then the Mac's active tab when the daemon exposes it.
- Offline: no push; the existing alert "<Mac> is offline" with last seen.

### Filter (toolbar menu)

`Menu` with an inline `Picker`: "All Macs", then each Mac, online first, each
with an icon (`laptopcomputer` / `desktopcomputer`; use `desktopcomputer`
until the model has a Mac kind) and its presence as the subtitle. The
filtered state fills the symbol (`line.3.horizontal.decrease.circle.fill`) and
sets the navigation subtitle. Remember per team with the existing
`MacFilter` key. Hidden when the team has one Mac.

### New Workspace

Unchanged `NewWorkspaceButton`: a tap creates at once on the filtered Mac,
else the preferred Mac, and pushes; a hold opens the options. The new row
appears at the top of Recent with the pending spinner.

### Long-press menu

- Section header: "<Mac> · <branch or directory>" (+ " · Offline").
- Online: one button per tab (the tab title, with `WorkspaceTab.systemImage`),
  which pushes that tab. Then a section with Rename and Close Workspace
  (destructive, confirmed). Rename and Close are hidden (not disabled) when
  `creator.canManage(ws)` is false.
- Offline: the header only, plus "Show <Mac>" (applies the filter).

### Trailing swipe

Close (system destructive, `.tint(nil)`, confirmed) and Rename (`.tint(.gray)`),
only when `canManage`. No leading swipe (the team drawer owns it). No full
swipe.

### States

- **Loading with cached data**: show the cached rows at full opacity. If the
  refresh takes more than 1.5 s, the navigation subtitle reads "Updating…".
- **Loading, no cache**: `SkeletonList` with two-line rows (title bar 45% ×
  14, subtitle 65% × 11, gutter empty) after 250 ms, 6 rows.
- **Failed**: unchanged `EmptyState` "Couldn't load workspaces" + Retry.
- **No Macs**: unchanged Connect your Mac.
- **Filtered to an online Mac with none**: "No workspaces on <Mac>", New
  Workspace.
- **Filtered to an offline Mac with none**: "<Mac> is offline", last seen.
- **Every Mac offline**: no Needs You or Recent; the folded offline lines
  appear expanded under an `EmptyState`-style header "Your Macs are asleep"
  (`moon.zzz`), so the user still sees what exists.
- **No search results**: `ContentUnavailableView.search`.

### Motion

- Status changes: the gutter symbol crossfades (`snap`); line 2 uses
  `.contentTransition(.opacity)`.
- A workspace that starts or stops needing you moves between sections with
  the list's insert/remove animation (`smooth`). Nothing else reorders on a
  status change.
- Insert (new workspace): the system insertion. Close: the system deletion
  after the confirmation.
- Offline fold: `smooth`, chevron rotation `snap`.
- Reduce Motion: no shimmer (static `label2`), and crossfades only.

### Accessibility

- Each row is one element: "cmux, Claude is waiting, Refactor transport
  layer, 1 minute ago" / "notes, idle, ~/notes, on Mac Studio, 1 day ago".
  Hint for offline: "Mac Studio is offline". Custom actions: Rename, Close.
- Section title rows have `.isHeader`; the offline line is a button with
  the value "Collapsed" / "Expanded".
- Dynamic Type to AX5: line 1 keeps the name and wraps it to 2 lines at AX
  sizes, the time moves below the name; line 2 allows 2 lines; the gutter
  stays 32 pt. Status is never color alone (each state has a word).
- Hit targets ≥ 44 pt (rows are ≥ 60).

### Liquid Glass (iOS 26 / 27)

System toolbar capsule and tab bar only; no glass on rows. Soft top edge.
Do not set bar backgrounds. On iOS 27 check the toolbar overflow behavior
with two trailing items, and the `navigationSubtitle` rendering under the
inline title.

### Data gaps the implementer must close

1. **Which tab is waiting / working.** `Workspace` has only workspace-level
   `needsAttention` / `isWorking`. `DaemonTree` knows the per-surface state
   (`AgentStates.bySurface`, `pending` per acpmux session). Add
   `agentState: String?` (`working` / `blocked` / pending) to `WorkspaceTab`
   in `DaemonTree.tab(...)`. Until then, use the first agent tab, which can
   name the wrong task when a workspace has two agents.
2. **Approval or question.** The model cannot tell a permission from a
   question, so the copy is "is waiting", not "needs approval".
3. **Activity time.** Live `lastActivityAt` is first sight. Ask the daemon
   for a per-workspace last-activity time (or derive it from `agent-changed`
   and `title-changed` events in `LiveCoordinator`: bump on each event). A
   wait-start time for Needs You sorting comes the same way (the moment the
   state became `blocked`).
4. **Mac's active tab.** `DaemonTree` computes `activeTab` but drops it.
   Store it as `Workspace.activeTabID` and use it after `TabMemory`.
5. **Mac kind** (laptop or desktop) is not modeled; use `desktopcomputer`.
6. **Done** relies on `unread_count` / `marked_unread`; confirm with the
   cmux-next team that agent completion sets it.

### Prototype notes

The prototypes' New, Rename and Close buttons do nothing (static data); the
production list wires them to `WorkspaceCreator` as today. The tab bar badge
in the screenshots comes from the app's mock store, not the prototype data.

## Rounds

### Round 1 — implementation

Direction A is built for real in `CmuxMobileWorkspaces`, replacing the ChatGPT-style list. The
prototypes and the `-cmux-mobile-wsproto` hook are kept for comparison.

**What was built**

- `WorkspaceInbox.swift` (new, platform neutral, unit tested): `WorkspaceStatus` (Creating >
  Offline > Needs you > Working > Done > Idle), the sections (Needs You, Recent, one `Fold`
  per offline Mac, or per online Mac the phone is not linked to in live mode), sorting,
  search (name, branch, directory, Mac name, agent tab titles and tasks), and the live
  list states (`isLoading`, `isUpdating`, `allAsleep`). `Workspace.agentTab(for:)` picks the
  tab a status is about.
- `WorkspacesList.swift`: the Inbox view per the spec: `navigationSubtitle`, the toolbar
  filter `Menu` (inline `Picker`, filled symbol when filtered, reuses `MacFilter`'s key),
  two-line `WorkspaceRow` with the 32 pt gutter and `StatusLine` (working is one
  shimmering `WorkingLabel` text), scrolling section titles, offline folds, row menu with
  the workspace's tabs, trailing swipe Close (`.tint(nil)`) and Rename (gray), custom
  accessibility actions, AX layout (name wraps, time under it). `NewWorkspaceButton`,
  `ConnectMacEmptyState`, `PullDownSearch`, rename and close flows are unchanged.
- Opening: needs-you rows note the waiting tab (`store.noteOpened`) before the push, so
  `WorkspaceScreen` lands on it; every open calls `store.markSeen` (clears Done).
- Removed: `MacChipRow`, `MacChip`, `RecencyHeader`, `WorkingDot`, the rounded press style,
  `RecencyBucket`, `RecencySection`, `WorkspaceListLayout` and their tests; the live link
  line moved into the filter menu's Mac subtitles.
- `MockData`: the Manaflow team is now two Macs (Aziz's Mac Studio online, MacBook Pro
  offline, last seen 2h) and 11 workspaces: two need you (Claude, and Codex on a second tab),
  two working, one done, idle ones, three on the offline Mac. Ids the demo and tests use
  (`ws-cmux`, `t-claude`, `ws-web`, `ws-notes`, …) are kept. The Personal and Build Fleet
  teams are unchanged.

**Data gaps**

1. Per-tab state: done. `WorkspaceTab.agentStatus` (`working` / `waiting`) is filled in
   `DaemonTree.tab(...)` from `AgentStates.bySurface` (`blocked` → waiting, `working`) and
   acpmux `pending` for conversation tabs. Rows name the waiting tab's agent and task; a tap
   lands on that tab.
2. Approval vs question: not distinguishable; the copy is "is waiting".
3. Activity time: the daemon reports none (`focused_at` on panes is a focus sequence, not a
   time). `WorkspaceSync` now stamps a surface when an `agent-changed` (state change) or
   `title-changed` event arrives; `DaemonTree` takes the newest stamp per workspace and keeps
   a known time across relists. A workspace with no event since the phone connected has
   `hasActivityTime == false`: it shows **no time** (never first sight), sorts after timed
   rows, in the Mac's focus order (`Workspace.focusOrder` = max pane `focused_at`). A
   wait-start time for Needs You is the same event stamp (the `blocked` transition), so
   Needs You sorts by it, newest first, as the spec says. Deferred: a daemon-reported
   per-workspace activity time would give times to rows idle since connect.
4. Mac's active tab: done. `DaemonTree` stores it as `Workspace.activeTabID`;
   `AppStore.openingTab` uses it after the device's last-used tab.
5. Mac kind: not modeled; `desktopcomputer` everywhere.
6. Done: from `unread_count` / `marked_unread`, cleared locally on open
   (`AppStore.seenAt`, this session) until the workspace has newer activity. Whether agent
   completion sets the Mac's unread flags is still to be confirmed with the cmux-next team.

**Honest states (live)**: `AppStore.workspaceListSync` records which Mac's list is current
(listed on the open link) or loading (the link's target before its first list), maintained
by `LiveCoordinator`. Nil in mock mode. The list shows a skeleton instead of "No
workspaces" while the linked Mac's first list is pending, keeps cached rows with
"Updating…" after 1.5 s, and shows an online Mac the phone is not linked to (it links one
Mac at a time) as "<Mac> · Not connected" (a tap links it) instead of stale rows; filtered
to such a Mac: "<Mac> isn't connected" + Connect.

**Tests** (Swift Testing, `swift test` on macOS, all green): `CmuxMobileWorkspacesTests` 23
(new `WorkspaceInboxTests`: sections and ordering, status priority, filter, search, every
Mac asleep, no-time ordering, live list states, pending rows, the waiting tab; new
`OpeningTabTests`: waiting tab, Mac's active tab, Done cleared on open, the mock mix),
`CmuxMobileModelTests` 40, `CmuxMobileLiveTests` 46 (new: per-tab agent state + `activeTabID`, activity
times only from events). The whole package's suites pass.

**Evidence** (git-ignored) in `verify/evidence/2026-10-13/wsdesign/round1/<run>/`:
`ios26-dark`, `ios26-light`, `ios26-ax` (accessibility-extra-large), `ios27-dark`,
`ios27-light`. Each: 19 step screenshots (`01-list` … `19-back`), `walk.mp4`, 2 fps
`frames/`. Recorded with real HID touches by `verify/record-wsdesign.sh <udid> <dir>
[dark|light] [content-size]` on a headless iPhone 17 Pro (iOS 26.5, then iOS 27.0), one
simulator at a time, deleted afterwards. Steps: list at launch, filter menu, each Mac,
offline Mac filtered, offline row explained, back to All, offline fold expanded, offline
row tapped, pull-down search and "fix", row menu (tabs, Rename, Close), swipe left (red
Close, gray Rename in dark and light), close confirmed, New Workspace tap (pushed, then the
pending row at the top of Recent), New Workspace hold (options), ghostty (needs you) opened
on its second tab "Resolve merge…" (Codex), back.

**Known gaps and defects**

- The inline `Picker` in the filter menu drops the Mac's presence subtitle; presence shows
  in the navigation subtitle once filtered, and the offline Mac is visible as its fold line.
- Filtered to an offline Mac, its fold line repeats the navigation subtitle's presence.
- Live mode was not exercised against a real cmux-next Mac in this round (mock only).
- At accessibility sizes the context menu fills the screen (system behavior); line 2 at
  AX sizes truncates long tasks at two lines.

### Round 1 — design review

Reviewed every step screenshot of the five runs (`round1/{ios26-dark,ios26-light,ios26-ax,ios27-dark,ios27-light}/01…19`)
and the 2 fps frames of `ios26-dark` (`frames/f001…f263`) for the transitions. Paths below are
under `verify/evidence/2026-10-13/wsdesign/round1/`.

The list matches the spec closely. Hierarchy, status words, folds, the toolbar menus,
the swipe tints and the opening of the waiting tab are right. iOS 26 and iOS 27 render the
same list; the only differences are on other screens (the terminal key bar). Dark and light
tints are correct, including the red Close and the gray Rename.

**Major**

1. **The waiting tab does not show what it waits for.** The list says "Codex is waiting ·
   Resolve merge conflicts". A tap opens that tab (`18-opened-waiting-tab.png`), but the
   transcript shows a finished answer with no permission or question card. During the push
   it briefly shows "Working" (`ios26-dark/frames/f248.png`). The list and the screen it
   opens disagree, so the feature is unproven. Fix: give the mock session behind the waiting
   tab (`ws-ghostty`'s Codex tab, and `t-claude`) a pending permission or question, so the
   card is on screen when it opens. Re-record step 18 with the card visible.

**Minor**

2. **Filter menu has no presence** (known): `02-filter-menu.png`. Fix: replace the inline
   `Picker` with `Button`s (a checkmark on the chosen one), each labeled with a `Text` title
   and a `Text` subtitle ("Online" / "Last seen 2h ago", and the link line in live mode).
   Keep the "All Macs" row first.
3. **Filtered to an offline Mac, the fold line repeats the subtitle** (known):
   `04-filter-offline-mac.png`. Fix: when the filter is that Mac, drop the fold line and show
   its rows directly. The navigation subtitle already says "Last seen 2h ago".
4. **Expanding a fold below the viewport shows no change except the chevron**:
   `ios26-dark/frames/f088.png` to `f098.png`. The rows appear off screen. Fix: after the
   expand, `ScrollViewReader.scrollTo` the fold's first row (anchor `.bottom`, `smooth`) when
   it is below the visible area.
5. **The close confirmation points at the wrong place**: `13-close-confirm.png`. The popover
   anchors near the top of the list, not the "design system" row. Fix: attach the
   `confirmationDialog` to the row (or present it from the swipe action's row) so the arrow
   points at it, as Mail does.
6. **Row menu tab names disagree with the row**: `11-row-menu.png`. The row says "Codex is
   working · Fix pricing page layout"; the menu item says "Codex". Fix: title an agent tab
   item with its task title (the same text as line 2) and give it the harness as a subtitle
   ("Codex"); terminals and browser tabs stay as they are.
7. **Working text is too faint**, worst in light mode: `ios26-light/01-list.png`
   ("Codex is working" reads near `label3`). Fix: shimmer from a `label2` base to a `label`
   highlight, so at rest it is never fainter than the rest of line 2.
8. **AX sizes: the time takes a whole line**, between the name and the status:
   `ios26-ax/01-list.png`. The first screen shows only 2.5 workspaces. Fix: at accessibility
   sizes, append the time to the end of line 2 ("… · 1m") instead of its own line. Keep it
   trailing on line 1 when it fits (`ViewThatFits`).
9. **AX sizes: the gutter marks do not scale**. The spinner touches "cmux.com" and the dots
   read as tiny bullets: `ios26-ax/01-list.png`. Fix: `@ScaledMetric(relativeTo: .body)` for
   the gutter width (32 at Large) and the disc sizes (10 and 8).
10. **New workspace line 2 is a bare "~"**: `16-new-in-list.png`. Fix: show the home
    directory as "Home" (the same word as the Recent Directories menu).

**Nits**

11. Needs You sorts newest first (`01-list.png`: cmux 1m above ghostty 25m). Accepted:
    it matches Recent and Mail. My spec contradicted itself ("longest waiting first" and
    "descending"); read it as newest first.
12. Search results have no section titles (`10-search-results.png`). Accepted: Mail and
    ChatGPT drop sections in results. Amend the spec.
13. The pending spinner never appears in the evidence (`15`→`16`: the mock confirms at
    once). Add a mock delay behind a debug flag and capture one frame of it.
14. Swiping hides the row's name and leaves only "2h" next to the actions
    (`12-swipe-close.png`). This is system behavior; leave it.
15. `MacBook Pro` uses `desktopcomputer` (`02-filter-menu.png`). Known: no Mac kind in the
    model.
16. `verify/record-wslist.sh` (known) drives chips that no longer exist. Delete it, or
    point it at `record-wsdesign.sh`.

**Checked and right**

- Honest states: offline rows explain on tap (`05`, `08`); New is disabled while filtered
  to the offline Mac (`04`); the tab badge (2) matches Needs You.
- No dead controls on the list, its menus or swipes.
- Motion: menu open and close, the filter change, swipe, push and pop and the search
  drawer are all system transitions with no jumps (`frames/f012`–`f019`, `f175`–`f196`,
  `f208`–`f216`). The search field appearing after a scroll back to the top is the
  standard drawer behavior.

**Verdict: not yet.** Fix 1 (major) and 2 to 10, then re-record. Everything else can ship
as is.

### Round 2 — implementation

Every finding of the round 1 review is fixed. Evidence is under
`verify/evidence/2026-10-13/wsdesign/round2/{ios26-dark,ios26-light,ios26-ax,ios27-dark,ios27-light}/`
(20 step screenshots each, `walk.mp4`, 2 fps `frames/`), recorded with real HID touches by
`verify/record-wsdesign.sh` on one headless simulator at a time (iPhone 17 Pro, iOS 26.5,
then iOS 27.0), deleted afterwards.

| # | Defect | Fix | Evidence |
| --- | --- | --- | --- |
| 1 | The waiting tab showed a finished answer, and "Working" flashed during the push. | The tab's `agentStatus` reaches the session (`AgentSessionDirectory` sets `summary.status` to `.waiting` / `.running`). A waiting `MockAgentSession` opens with a turn on the tab's task blocked on the person: Claude asks the transport question, other agents ask to run `git add -A && git merge --continue`; answering finishes the turn. The flash was a half-replayed history (a past turn still running between stream events): the mock now sends its history and the waiting turn's opening as one `AgentSessionEvent.batch`, applied in one change by `AgentChatStore`. | `ios26-dark/18-opened-waiting-tab.png` ("Codex wants to run a command", Allow once / Deny); `ios26-dark/frames/f183`–`f195` (push: the card is there from the first frame, no "Working"); same step in every run. |
| 2 | Filter menu had no presence. | `Toggle`s with a title `Text`, a subtitle `Text` and the icon directly in the label (a `Label` or an inline `Picker` drops the subtitle); the chosen one has the checkmark. Ids `workspaces.filter.<mac>`. | `*/02-filter-menu.png` ("Online", "Last seen 2h ago") |
| 3 | Filtered to the offline Mac, the fold line repeated the subtitle. | No line when the filter is that Mac; its rows only. | `*/04-filter-offline-mac.png` |
| 4 | Unfolding below the viewport showed nothing new. | The line records its bottom in the list (`onGeometryChange`, `.scrollView`) and the list its visible bottom (`onScrollGeometryChange`); when the first new row would not fit, `ScrollViewReader.scrollTo(first, anchor: .bottom)` with `smooth`. | `ios26-ax/07-offline-expanded.png` (the line was at the bottom; `zed` scrolled into view), `ios26-dark/07` |
| 5 | The close popover pointed near the top of the list. | Anchored at the row: a dialog on the row itself is dropped while its swipe actions close, so the dialog sits on an anchor view over the list, sized and placed (padding, not offset: the popover uses the layout frame) at the row's frame. Row frames go into a plain reference box, so scrolling does not re-render the list. The row menu's Close uses the same anchor. | `*/13-close-confirm.png` (arrow on "design system") |
| 6 | Row menu said "Codex" where the row says the task. | An agent tab item is titled with its task, the agent as the subtitle; terminals and browsers unchanged. | `*/11-row-menu.png` ("Fix pricing page layout" / "Codex") |
| 7 | "is working" too faint, worst in light. | `ShimmerText`: `label2` at rest with a `label` highlight sweeping across (static `label2` with Reduce Motion), replacing `WorkingLabel`'s `.secondary` base on a `label2` foreground. | `ios26-light/01-list.png`, `ios27-light/01-list.png` |
| 8 | At AX sizes the time took a whole line. | The time stays trailing on line 1 beside a name that wraps to two lines (`fixedSize` time); no line of its own. The first AX screen shows 3.5 workspaces instead of 2.5. | `ios26-ax/01-list.png` |
| 9 | AX gutter marks did not scale; the spinner touched the name. | `@ScaledMetric(relativeTo: .body)` gutter (32 at Large) and discs (10, 8); the separator inset uses the same scaled gutter. | `ios26-ax/01-list.png` |
| 10 | New workspace line 2 was "~". | The home directory reads "Home" on idle and creating rows. | `*/16-new-pending.png`, `*/16b-new-confirmed.png` |
| 13 | The pending spinner was never captured. | DEBUG launch argument `-cmux-mobile-mock-create-delay <seconds>` (`ShellModel`) holds mock creations open; the script uses 8 s. | `*/16-new-pending.png` (spinner in the gutter, "New Workspace · Home · now"), then `16b-new-confirmed.png` |
| 16 | Stale `verify/record-wslist.sh`. | Deleted (`git rm`); `verify/workspaces-list.md` notes it was replaced by `record-wsdesign.sh`. | — |

Nits 11, 12, 14 and 15 are accepted as the review says; SPEC 11.1 now says Needs You sorts
newest first and a lone Recent section has no title in search results.

**Tests**: `swift test` in `CmuxMobileKit` passes every suite: CmuxMobileWorkspacesTests 23,
CmuxMobileModelTests 40, CmuxMobileLiveTests 46, and the AgentChat store suite 38 tests in 14 suites (new
`waitingMockSessionsOpenOnTheirCard`: the history and the waiting turn arrive as one change
with every past turn completed, the Codex permission and the Claude question are pending,
and answering finishes the turn).

**Script changes** (`verify/record-wsdesign.sh`): the filter menu is driven by ids, the
app launches with `-cmux-mobile-mock-create-delay 8`, and step 16 is split into `16-new-pending`
and `16b-new-confirmed`.

**Known**: one frame during the New Workspace menu dismissal (`ios26-dark/frames/f188`)
shows the list shifted by the search drawer for 0.5 s (the drawer collapses as Escape
dismisses the menu); this is a script artifact of the hardware Escape key.

### Round 2 — design review

Reviewed every step screenshot of the five runs in `round2/` and the `ios26-dark` 2 fps
frames around each transition. Paths are under `verify/evidence/2026-10-13/wsdesign/`.

**Round 1 findings: all fixed.**

1. The waiting tab opens on its card ("Codex wants to run a command", Allow once / Deny /
   Reply instead) with no "Working" flash (`round2/*/18-opened-waiting-tab.png`,
   `round2/ios26-dark/frames/f190`–`f191`).
2. The filter menu shows "Online" / "Last seen 2h ago" under each Mac (`round2/*/02`).
3. Filtered to the offline Mac, there is no repeated line (`round2/*/04`).
4. The fold scrolls its first row into view (`round2/ios26-ax/07`).
5. The close popover points at "design system" at Large on iOS 26 and 27 (`round2/ios26-dark/13`,
   `round2/ios27-dark/13`). It looks native; the anchor view is not visible. See new 3 for AX.
6. The menu titles the agent tab with its task and the agent as its subtitle (`round2/*/11`).
7. "is working" reads at `label2` in both modes (`round2/ios26-light/01`).
8. and 9. At AX sizes the time stays trailing and the gutter scales; 3.5 rows fit
   (`round2/ios26-ax/01`).
10. The new workspace reads "Home", and the creating spinner is captured
    (`round2/*/16-new-pending.png`).

**New in round 2 (minor)**

1. **The gutter and row height regressed at Large.** Text now starts about 48 pt from the
   edge (was 32) and the row pitch is about 72 pt (was 61). Compare
   `round1/ios26-dark/01-list.png` (names at x≈97 px) with `round2/ios26-dark/01-list.png`
   (x≈145 px). The list feels indented, and the offline Mac's line is now hidden under the
   tab bar on the first screen, so the user cannot see that a Mac is offline without
   scrolling. Fix: the `@ScaledMetric` base must give 32 pt at `.large`. Check the
   initial value and that no padding is added to it twice, for example a leading inset
   plus the gutter frame. Restore 10 pt vertical row padding. Re-check that the separator
   inset follows.
2. **A swiped row turns into a gray pill with one clipped letter** ("m … 2h",
   `round2/ios26-dark/12-swipe-close.png`, light too). Round 1 showed no fill
   (`round1/ios26-dark/12`). It is the row's pressed or highlight fill staying on during
   the swipe. Mail shows no fill there. Fix: do not draw a press fill on rows (let `List`
   own selection), or clear it when a swipe begins. Keep `listRowBackground(bg)`.
3. **At AX sizes the close popover points at the wrong row.** The arrow points at cmux-next-ios's
   status line, about 80 pt above the swiped "design system" row
   (`round2/ios26-ax/12` → `13`). The stored row frame is stale or measured in another
   coordinate space at large type. Fix: read the row's frame at the moment Close is
   tapped, in the same named coordinate space as the anchor overlay. Add an AX check
   of step 13 to the script.

**Nits**

- `round2/ios26-dark/frames/f186`–`f188`: the list drops about 15 pt under the search field for
  one frame as the New Workspace menu closes. The script closes the menu with the hardware
  Escape key (`record-wsdesign.sh` line 90), which also goes to the search controller, so
  the implementer's explanation is plausible. Escape is a real input on iPad and with a
  keyboard, though. Next recording, close the menu with a tap outside. If the shift is
  gone, accept it; if not, it is an app issue.
- The MacBook Pro still shows a desktop icon (known; no Mac kind in the model).

**Taste.** The list now reads like a first-party app: status in words, attention first,
system menus, swipes, popovers and pushes, correct in dark, light and at AX sizes, and the
same on iOS 26 and 27. New 1 is the one visible step back; with it fixed I would show this
to the user without hesitation.

**Verdict: SIGN OFF** (no major issues). Fix new 1 to 3 before handing the build to the
user; the nits are optional.

### Round 3 — implementation

Fixes the three items of the round 2 review, the Escape nit, removes the prototypes and
merges `origin/feat-cnx-ios`. Evidence: `verify/evidence/2026-10-13/wsdesign/round3/`
(`ios26-dark`, `ios26-light`, `ios26-ax`, `ios27-dark`, `ios27-light`: 20 steps,
`walk.mp4`, 2 fps `frames/` and `check-13.txt` each), plus hero shots `final-dark.png` and
`final-light.png` (iOS 26.5, Large, list at launch, clean status bar). One headless
simulator at a time, each deleted afterwards.

| # | Defect | Fix | Evidence |
| --- | --- | --- | --- |
| 1 | Gutter about 48–64 pt and rows about 72 pt at Large; the offline line fell under the tab bar. | `@ScaledMetric(relativeTo: .body)` in list rows scaled 32 pt to about 64 pt at Large (the round 2 dot center was at x 32 pt). The gutter and discs now scale with `UIFontMetrics(.body)` from the environment's Dynamic Type size, exactly the value at Large; the separator inset uses the same function. The row padding was never changed (10 pt); the taller rows most likely came from the doubled disc metric in the gutter's baseline alignment, and are gone with it. | `round3/ios26-dark/01-list.png` matches `round1/ios26-dark/01-list.png` (text at 32 pt, same row pitch, the MacBook Pro line above the tab bar); `final-dark.png`, `final-light.png` |
| 2 | A swiped row became a gray pill. | The List cell highlight (default button style in a List) stayed on during the swipe. Rows use `RowPressStyle`: a full-row `fillSelected` fill only while the finger is down; a swipe or scroll cancels the press. `listRowBackground(bg)` kept. | `round3/*/12-swipe-close.png` (no fill; only "2h" beside the actions, which is system behavior) |
| 3 | At AX sizes the close popover pointed about 80 pt off. | Two causes. SwiftUI geometry callbacks inside list cells did not follow scrolling, so the stored frame went stale: each row and the anchor overlay now carry a UIKit probe view, and the row's frame is converted into the overlay's space at the moment Close is tapped. And at AX sizes the popover is nearly screen-tall and cannot sit beside a row in the lower half: the row first scrolls to the top (`smooth`, then the popover in the animation's completion) and the popover opens under it. The script checks step 13 at every size: the popover's text must sit just above or below the swiped row without covering it. | `round3/ios26-ax/13-close-confirm.png` (row at the top, popover under it, arrow on its bottom edge); `check-13.txt`: PASS in all five runs (gap 24.7 / 35.0 pt at Large, 133 pt at AX-XL where the popover's own padding is larger) |
| nit | New Workspace menu closed with the hardware Escape key; one-frame list shift. | The script closes it with a tap outside (left side, below the menu). No shift in the frames around the dismissal (`round3/ios26-dark/frames`, the last 30 frames). | — |

**Cleanup**: `CmuxMobileWorkspaces/Prototypes/` and the DEBUG `-cmux-mobile-wsproto` hook in
`CmuxMobileShell/Screens.swift` are deleted. The prototypes live in commit `274eedb0fe6d`; their
screenshots stay in `wsdesign/directions/`.

**Merge** (commit `a3229fc1562b`, 57 upstream commits). `origin/feat-cnx-ios` added its own
honest-state model, `MacDataMachine` (per-Mac phases: live, cached snapshot, loading,
failed, offline, idle) fed by `LiveCoordinator`, and a launch snapshot of every Mac's
workspaces. My `WorkspaceListSync` overlapped it and is removed; `WorkspaceInbox.Context`
now takes the phases (`ListState`: live, loading, cached(updating), failed, notConnected).
Behavior: cached rows show dimmed (55 %, the upstream treatment) with no agent state, so a
cache never says "is waiting"; a failed dial with nothing known is a "<Mac> · Can't
connect" line that retries; the filter menu's subtitle uses upstream's `macStatusLine`
("Online · Connecting…") plus the link line; the `ConnectTimeline` row marks are kept.
`Workspace` decodes snapshots saved before `hasActivityTime`, `focusOrder` and
`activeTabID` existed. `DaemonTree` keeps both the focus order and upstream's per-Mac
active pane. The app build used the `CmuxMobileLinkFFI.xcframework` built for the same Rust tree
(`origin/feat-cnx-ios` `a074414f18c7`, copied from the `feat-cnx-ios` worktree).

**Script** (`record-wsdesign.sh`): warms up the automation session on a fresh simulator
(the first iOS 27 run timed out), closes the New Workspace menu with a tap, and writes
`check-13.txt`.

**Tests**: `swift test` in `CmuxMobileKit`, every suite green after the merge (CmuxMobileWorkspacesTests
23, CmuxMobileModelTests 56, CmuxMobileLiveTests 55, the AgentChat suites 43, and the rest);
`liveListStates` now covers the cached, failed, loading and not-connected phases.

**Known**: on opening the waiting tab, the chat's composer shows for one frame before the
permission card replaces it (`round3/ios26-dark/frames`, near the end). The status bar
in the `ios26-*` walk recordings shows a "◂ Settings" back link from an earlier Settings
launch on that simulator; the hero shots were taken on a fresh simulator without it.

### Round 3 — design review

Reviewed the 20 steps of all five `round3/` runs, the `ios26-dark` frames at the end of
the walk, `check-13.txt` and the two hero shots. Paths are under
`verify/evidence/2026-10-13/wsdesign/`.

**Round 2 findings: all fixed.**

1. Gutter and row pitch are back to round 1. Text starts at about 32 pt, and the MacBook
   Pro line sits above the tab bar on the first screen (`round3/ios26-dark/01-list.png`,
   `round3/ios27-light/01-list.png`).
2. A swiped row has no fill; only "2h" stays beside Rename and Close, which is the
   system's behavior (`round3/ios26-dark/12-swipe-close.png`).
3. At AX sizes the swiped row scrolls to the top and the popover opens directly under
   it, arrow on the row (`round3/ios26-ax/13-close-confirm.png`). At Large the popover
   sits just below the row on iOS 26 and 27 (`round3/ios26-dark/13`). `check-13.txt`
   passes in all five runs.
- Nit: the New Workspace menu now closes with a tap, with no list shift in the frames.

**Merge.** No visual regressions in mock mode: sections, status words, folds, filter
menu (now "Online" / "Last seen 2h ago"), offline explanations, the pending row and the
waiting card all match round 2. The cached, failed and loading states from
`MacDataMachine` are not in these recordings. They are covered by `liveListStates`, and
cached rows that never claim "is waiting" are the right call. Verify them visually in
the first live dogfood.

**The two knowns**

- **The composer shows for one frame before the waiting card**
  (`round3/ios26-dark/frames/f893.png`, "Reply to Codex", then the card from `f894`).
  Acceptable for now: it is under 0.5 s, on the chat screen, not the list. Follow-up
  for the chat owner: when the session opens with a pending request, start in the
  action-bar state instead of swapping it in after the first layout.
- **"◂ Settings" in the status bar** of the iOS 26 walks. Acceptable: it is the system's
  return-to-app link left by an earlier launch on that simulator. It is not in the hero
  shots or the iOS 27 runs.

**Hero shots** (`round3/final-dark.png`, `round3/final-light.png`). Ready for the user.
Clean status bar, Large type, nothing clipped, correct tints in both modes, and the screen
answers the four questions at once: two workspaces need you (in words, on top), two are
working, one is done, and the MacBook Pro is offline with its last-seen time. The black
pill in the light shot is the Dynamic Island, not an artifact.

**Verdict: SIGN OFF (final).** No open defects in the list. One follow-up outside it:
the chat's first-frame composer.
