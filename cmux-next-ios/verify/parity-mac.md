# Phone parity with the cmux-next Mac app

Branch `feat-cnx-ios-parity`, 2026-10-14. The person's report: "I can't create
browser tabs or GUI sessions on iOS. GUI sessions should open model-agnostic,
not with New Claude Chat. I should be able to do everything I do on cmux-next
Mac on my phone."

The Mac's actions come from its action catalogs (`Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/*`,
`origin/feat-cmux-next` c6416c53) and the agent pane strings
(`webviews/src/agent-session/acpmux/generated/strings.json`).

States: **works** (on the phone and verified), **partial** (on the phone with
a stated limit), **missing** (not on the phone yet), **not from a phone**
(kept off the phone on purpose, with the reason).

## Creation (priority 1)

| Mac action (wording) | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| New Agent Chat (⌘I) | acpmux `session/new` (harness from the last pick, else acpmux `defaultHarness`), daemon `new-conversation-tab` | + > **New Agent Chat** | works (round 2) | One model-agnostic entry. Round 2: it starts where the Mac's would: the Mac's last pick in the workspace folder, then its last pick anywhere, then the agent it picked last, then acpmux's `defaultHarness` (a pick the phone can't start is skipped). The Mac app hands its `newTab.lastPicks` to acpmux over its person connection (`_acpmux/new_chat_picks_set`, memory only) and `_acpmux/harnesses` shows them (`lastPicks`). Round 3 live (`last_pick` pass, twice): the rig Mac's own New Tab page model picker, driven in the background on the mini (accessibility actions), picked Haiku 5.5, later Sonnet 5.5; acpmux's `lastPicks` followed at once, and the phone's New Agent Chat started on that model (Mac session `claude-haiku-5-5`, then `claude-sonnet-5-5`, policy `ask`). |
| Harness and model picker (chip: "Harness", "Model"; "Unavailable" + reason) | `session/new` then `session/set_model` | + > **New Agent Chat With…** (sheet "New Agent Chat": Harness, Model, Start Chat) | works (round 2) | acpmux now says per agent what a phone may start (`remote: {startable, modes}` or the reason). **Codex** (the `codex app-server` bridge, the Mac's `codex` profile) is startable: a phone-started Codex chat begins in the bridge's **Ask** mode (approval policy `untrusted`: Codex asks before every command that is not a known-safe read and before every file change), with acpmux policy `ask`, so each approval reaches the phone and Allow needs Face ID. The codex-acp adapter stays "Not available from here: this agent has no mode that asks before each change". **opencode** stays unavailable with "Not available from here: opencode's own settings on this Mac can let it edit and run commands without asking" (round 3: acpmux cannot force its asks; see "Remaining gaps"). A Mac without the `remote` row keeps Codex refused. |
| Agent chat in a workspace folder | `session/new {cwd}` (the pane's folder) | same | works (this branch) | Needed `feat-cnx-ios-agentcwd` (acpmux `_acpmux/workspace_roots_set`), merged here. A workspace still at home gets "Agent chats start in a project folder…". A folder Claude has never been trusted in waits on the Mac's trust question (see Gaps). |
| New Terminal Tab (⌃`) | `new-tab {cwd}` | + > **New Terminal** | works | hostd picks the pane's folder (`with_pane_folder`); the phone never sends `cwd`. |
| New Browser Tab (⇧⌘L) | `new-frontend-browser-tab` | + > **New Browser Tab** | works on a Mac that streams (`browser-stream-v1`) | An older Mac now keeps the entry; a tap says "Update cmux on <Mac> to open browser tabs from your phone." (was: silently missing). |
| New Workspace (⌘N) | `create-workspace`, `create-terminal {cwd}` | **New Workspace** (tap) | works | Mac default folder (home). |
| New Workspace in a folder / Open Folder… (⌘O) / New Workspace Like This | `create-workspace` + `create-terminal {cwd}` | New Workspace (hold) > **Recent Directories**, **Open Folder…** (parity2) | partial | Recent Directories: the folders of the Mac's workspaces and the ones used on this phone. Open Folder… takes a typed full path (`/…`, `~`, `~/…`); a relative path is refused with "Type the folder's full path on <Mac>, starting with / or ~/.". The new terminal types `cd '<folder>' && clear`, since the phone sends no `cwd`; a folder with a control or format character, a backslash or `!` is never typed ("Open it in cmux on <Mac>"). A folder that does not exist shows the shell's own `cd` error in the new terminal. Not possible from a phone: browsing the Mac's folders (no file picker over the link). |
| New Browser Workspace (⌥⌘N) | `new-frontend-browser-tab` | New Workspace (hold) > **New Browser Workspace** | works | |
| New Agent Chat over Home (a workspace whose only tab is the chat) | `create-workspace`, `new-conversation-tab` | New Workspace (hold) > **New Agent Chat** > a folder (parity2) | works (parity2, live: `agent_chat_workspace` pass) | acpmux `session/new` in that folder first (a folder not trusted yet leaves no empty workspace), then `create-workspace` and `new-conversation-tab {workspace}` (the daemon makes its first pane). The Mac's default agent. Folders: the Mac's workspace folders (Recent Directories) only, since acpmux's remote guard starts a phone's chat only there; any other folder says to open a workspace there first (New Workspace › Open Folder…). No new allowlist entry. |

## Tabs

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Close Tab (⌘W) | `close-surface` | grid ×, page menu Close Tab | works | Asks first when a program runs. |
| Close Tabs to the Left / to the Right | `close-surface` × n | card and page menu **Close Tabs to the Left / to the Right** (each only when it has a tab to close) | works (menu-rows batch; live) | The unpinned tabs before or after the tab in its own pane on the Mac (`TabStripModel.closedByCloseToLeft`), never in Home. One question when one of them runs a program, as Close Tab asks. |
| Rename Tab… (⌘R) | `rename-surface` | page and card menu **Rename Tab…** | works (this branch) | Rolls back on refusal. |
| Duplicate Tab | `new-tab` / browser duplicate / a second tab of the chat | page and card menu **Duplicate Tab** | works (parity2 tabs) | Terminal: a new terminal in the tab's pane (hostd's folder choice). Browser: the same http(s) page. Agent chat: a second tab of the same chat (`new-conversation-tab` with the tab's session), as the Mac's `duplicateAgentTab`; never a copy of the conversation (that is Fork). |
| Move Tab Left / Right, drag | `move-tab` | drag in the grid | works (parity2 tabs; live) | Within the tab's pane (insertion index as the daemon reads it); a drag onto another pane's tab says to move it on the Mac. A real long press and drag is proven by an XCUITest (`CmuxMobileAppUITests/TabReorderUITests`: first card to the third slot, iOS 26.5 simulator, mock data); `pq_tabs.reorder` runs it against the rig Mac. |
| Move Tab to Workspace… / Move Tab to New Workspace | `move-tab-to-workspace {surface, workspace}`, `move-tab-to-new-workspace {surface, name}` | page menu **Move Tab to Workspace…** (a picker of this Mac's other workspaces), **Move Tab to New Workspace** | works (parity2 tabs; live) | The Mac's More rows, so on the phone they are in the page menu (the card menu has no room). The new workspace is named by the Mac's rule (`NewWorkspaceName`: a last tab keeps its workspace's name; else the tab's name, page title or host, terminal title unless a bare shell, then its folder). The tab keeps its terminal, page or chat; the phone stays in the source workspace (the Mac's own view is its own) and says "Moved <tab> to <workspace>."; leaving it when that was the last tab. A tab in Home has no Move Tab to New Workspace ("Home's tabs stay in Home."), as on the Mac. |
| Move Tab to New Split / Column, Move Tab to Pane Left / Right / Above / Below, Previous / Next Pane | `move-tab-to-split`, `move-tab-to-column`, `move-tab` across panes | — | not applicable (decision) | The phone shows a workspace's tabs as one list and has no panes to aim at; a pane move would change the Mac's layout with nothing on the phone to show it. Left off the phone on purpose; the commands stay allowlisted for a future pane view. |
| Pin Tab / Unpin Tab | `set-tab-pinned` | page and card menu **Pin Tab** / **Unpin Tab** | works (parity2 tabs; live) | Here at once, rolled back on refusal. A pinned tab's card icon is a pin; the Mac sorts pinned tabs first in their pane. |
| Split Right / Down, New Column, Zoom Pane | `split`, `new-pane-right`, `zoom-pane` | the Panes page (#27384) | works | See "Panes" below. |
| Reopen Last Closed Tab (⇧⌘T) | resource `closed.reopen` | — | not from a phone (yet) | The resource API is not on the phone's lane. |
| Restart Shell Here | `restart-tab` | dead terminal: overlay "The shell ended." + **Restart Shell Here**, page menu row | works (round 2) | Allowlisted with the surface only (no command, folder, env or alias), after live verification on the rig Mac that the new shell runs on the Mac under the same tab (SECURITY.md "Restart Shell"). The phone now lists a dead terminal the Mac keeps (it hid every dead tab). |
| New Tab Group, Add Tab to Group…, Remove Tab from Group | `create-tab-group {surfaces, color}`, `add-tabs-to-tab-group`, `remove-tabs-from-tab-group` | page and card menu, the Mac's group rows | works (parity2 tabs; live) | New Tab Group takes the Mac's next color (`GroupColor.automatic`, never blue or grey) and no name. A pinned tab offers no group rows ("Pinned tabs cannot be grouped." on the Mac). A member's card carries the group's chip (name, else "<Color> group"). |
| The group's chip menu: Rename Tab Group…, Pin Group / Unpin Group, Ungroup Tabs, Close Tab Group | `update-tab-group {name}`, `save-tab-group`, `unsave-tab-group`, `ungroup-tab-group`, `close-tab-group` | a member's menu > **Tab Group: <name>…** pushes the group's page (swipe back returns) | works (parity2 tabs; live) | The phone has no group chip to hold, so a member's row opens the group's page: its tabs, then Appearance, New Tab in Group, Move, and Pin / Ungroup / Close. Close Tab Group waits for the Mac, then removes every member. |
| Set Tab Group Color… (the nine colors), Set Tab Group Icon… / Remove Tab Group Icon, Collapse / Expand Tab Group | `update-tab-group {color}`, `{icon}` (null removes it), `{collapsed}` | the group's page > **Appearance** | works (groups-screens batch; live) | The Mac's nine group colors; icons are the 16 SF Symbols the phone's workspace icon menu offers, or **Emoji…** for one emoji (the Mac's picker has every symbol and images). The member cards' chip shows the color and icon; the page header says "Collapsed on <Mac>". The phone's grid has no strip, so a collapsed group's tabs still show there. Each change shows at once and comes back if the Mac refuses. |
| Move Tab Group Left / Right, to New Split (Right / Left / Above / Below), to New Column, to Workspace…, to New Workspace; New Tab in Group | `move-tab-group {group, pane, index}` (the Mac's `TabGroupReorder` index; another workspace's shown pane at its end), `move-tab-group-to-split {group, pane, edge}`, `move-tab-group-to-column {group, pane}`, `move-tab-group-to-new-workspace {group}`, `new-tab {pane}` + `add-tabs-to-tab-group` | the group's page > **Move**, **New Tab in Group** | works (groups-screens batch; live) | Left / Right show only when the group can move that way (not past the pane's edge or a pinned tab). A group in an agent chat dock is not split ("The agent chat can't be split.", as the Mac). Move Tab Group to Workspace… uses `move-tab-group` into the destination's first screen's default pane (never a chat dock), as the Mac's `tabGroup.moveToWorkspace`; the 2026-10-26 audit had it as off the lane, but that command is on it. No Move Tab Group to New Window (no windows on a phone). New Tab in Group's terminal is hostd's pane-folder shell (the phone names no folder). |
| Reopen Saved Tab Group…, Delete Saved Tab Group… | `reopen-saved-tab-group {saved, pane}`, `delete-saved-tab-group {saved}`, read `list-saved-tab-groups`, `list-tab-groups` | page menu > **Reopen Saved Tab Group…** / **Delete Saved Tab Group…** (a chooser of the Mac's saved groups; an open one shows "Open" and is not reopened) | works (round 3; live: `saved_group` pass) | Params narrowed on both policies to the saved id, the pane and a transaction (no command, folder, env or host). The daemon reopens each terminal as the login shell in its saved folder (or reattaches it while it runs), on this Mac (SECURITY.md "Reopen Saved Tab Group"). Live: new login shells under the rig app's own terminal host, in the saved folders (SECURITY.md "Reopen Saved Tab Group"). |

## Panes (ws-rows batch)

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Resize Pane Left / Right / Up / Down (`PaneResize.press`) | `set-split-ratio {split, ratio, transaction}` | Panes page > **Resize Pane**: a stepper per divider of the shown screen ("Pane 1 \| Pane 2, Left side 50%") | works (live: `panes` pass) | Each step moves the divider 5% on the Mac, between 10% and 90%; the value shown is the Mac's. |
| Move Tab to New Dock Column (`tab.moveToNewDockColumn`) | `move-tab-to-column {surface, pane, width, dock: {edge, mode}}` | Panes page > a tab's menu > **Move Tab to New Dock Column** > Left / Right / Top / Bottom | works (live: `panes` pass) | Docked mode, a left dock half the window, the others 30%, as `TabMoves.toNewDockColumn`. A daemon without `dock-columns-v1` (or `edge-docks-v1` for top/bottom) refuses, and the toast says why. |
| Move Pane to New Workspace (`pane.moveToNewWorkspace`) | `move-tab-to-new-workspace` for its first tab, `move-tab-to-workspace` for the rest | Panes page > a pane's ⋯ > **Move Pane to New Workspace** | works (live: `panes` pass) | Placed right below its workspace (`set-personal-workspace {index}`). The only pane is not offered (the Mac refuses it: "the pane is the only pane of its workspace"). |
| New Row (`newRow`) | `new-row {pane, height}` (rows-v1) | — | not from a phone (yet) | `new-row` is not on the phone's daemon lane (DaemonLanePolicy, policy.rs); it starts a terminal, so adding it is a lane change for #13742. |
| One concentric corner radius for panes and tabs: `layout.paneCornerRadius` (pane cards, the curved main pane, tab pills less the padding) and `layout.cornerPadding` (2026-11-04) | none: cmux-next.json keys the Mac's pane chrome reads | — | not from a phone | Mac-only chrome: they shape the Mac's pane cards and tab strips. The phone draws no pane cards or tab strips; the keys stay settable over `cmux settings` like any setting. |

## Screens

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| The screen bar (which screen a tab is on) | `list-workspaces` `screens[]` | each tab's card names its screen ("Screen 2", or its name) when the workspace has more than one; page menu > **Screens (N)** pushes the Screens page: one section per screen with its tabs, the current one marked | works (groups-screens batch; live) | The grid stays one list of every screen's tabs (CmuxTabsKit has no sections and is not changed here). |
| Select Screen / Next / Previous | the Mac's window-local switch (`LayoutModel.selectScreen`) | a screen's ⋯ > **Select Screen** | works (groups-screens batch; live) | Makes it the workspace's active screen in the daemon (where a phone's new tab opens), with `focus-pane` on the screen's active pane. The daemon's `select-screen {index, delta}` names no workspace (it picks among the screens of the daemon's active workspace), so it can't aim at the workspace the phone shows. Like any focus change it also makes the workspace the daemon's active one (what a terminal frontend following the session shows). The Mac's windows keep their own shown workspace and screen, as for any other client. |
| New Screen | `new-screen {workspace}` | Screens page **+** | works (groups-screens batch; live) | A new terminal (the Mac's login shell) on a new screen; the phone opens its tab. |
| Rename Screen… | `rename-screen {screen, name}` | a screen's ⋯ > **Rename Screen…** | works (groups-screens batch; live) | |
| Close Screen | `close-screen {screen, end_terminals: true}` | a screen's ⋯ > **Close Screen** (not on the only screen) | works (groups-screens batch; live) | Asks first when a tab on it runs a program; its terminals end with it (the phone has no Reopen Closed Screen), as a phone tab close ends its terminal. |
| Duplicate Screen | `ScreenCommands.duplicate`: `new-screen {name, color, icon, index, group, cwd}` | a screen's ⋯ > **Duplicate Screen** | partial (ws-rows batch; live: `screen` pass) | `new-screen {workspace}`, then `rename-screen` to the screen's name, and `cd '<folder>' && clear` typed into its terminal (the folder of the screen's shown tab), as New Workspace in a folder. A phone may send `new-screen` with only its workspace (policy.rs `creation_fields`), so the copy goes at the end with the Mac's default color and icon, not right after the original. |
| Reopen Closed, color, icon, pin, move, screen groups, Close Other / to the Right / Left | | | missing | Not in this batch (slice D rows P2/P3; reopen needs the closed-history resource, off the lane; color, icon, pin and move need a screen metadata write, off the lane). |

## Workspaces

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Rename Workspace… (⇧⌘R) | `rename-workspace` | row swipe / menu Rename | works | |
| Close Workspace (⇧⌘W) | `close-workspace` | row swipe / menu Close Workspace | works | |
| Close Other Workspaces / Close Workspaces Below / Above | `close-workspace` × n | row menu > **Close** > the Mac's three titles | works (parity2) | Over the Mac's sidebar order of that Mac's workspaces (pinned first). The Mac closes at once; the phone asks first ("Close 3 workspaces?", naming them), since a long press is easy to misplace. |
| Close Other Workspaces in Group, Close All Workspaces; the group menu's Close All in Group and Close Other Groups | `close-workspace` × n; for a group, `workspace_group.delete` (a pinned group: `workspace_group.update {collapsed: true}`) first | row menu > **Close** > **Close Other Workspaces in Group** / **Close All Workspaces**; group header menu > **Close All in Group**, **Close Other Groups** | works (menu-rows batch; live) | Asks first, as the other bulk closes. Home never closes. As the Mac's `closeGroup`, a pinned group stays folded and empty; another goes. A group whose delete is refused keeps its workspaces. Close All Workspaces closes every workspace of that Mac (a phone has no windows). |
| Move Workspace Up / Down | `set-personal-workspace {index}` (personal order), else `move-workspace {index}` | row menu > **Move** > **Move Workspace Up / Down** | works (parity2) for unpinned workspaces | The same index the Mac's `movePersonalWorkspace` computes. Pinned workspaces have no Move on the phone: the Mac orders its pinned tiles with a layout `item.move`, which is not on the phone's lane. No drag: a long press opens the row menu, and the list is not a reorderable List. |
| Move Workspace to Top / to Bottom (a grouped row: Move to Top / Bottom of Group), Sort Workspaces by Name / Last Used / Directory | `set-personal-workspace {index}` (else `move-workspace {index}`) per moved row | row menu > **Move** > **Move Workspace to Top / to Bottom**, **Sort Workspaces** > by Name / Last Used / Directory | works (menu-rows batch; live) | Top / Bottom of the row's own container (its group, else the loose rows), as `WorkspaceSlot.top / .bottom`. Sort sorts every container of that Mac in place, one row at a time as the Mac's sort places them; pinned rows keep their order (as the Mac). Last Used uses the workspaces' activity, then the daemon's focus order: the Mac sorts by its window's own recency, which a phone cannot see. |
| `cmux workspace <ws> move --index N` moves the sidebar row; `--top` / `placement: top` on `workspace create`, `agents chat new`, `agent.openSessionWorkspace` (https://github.com/manaflow-ai/cmux/issues/29875) | resource `workspace.move {index}` (session order and sidebar document), `workspace.create {placement}` | row menu > **Move** > **Move Workspace to Top** (the row move); a phone-made workspace goes where `workspaces.newPlacement` puts it | not from a phone | These are the CLI, MCP and agent entry points of moves the phone already has from its row menu (`set-personal-workspace`). A placement override for agent-made workspaces is automation on the Mac (the Chief, scripts); a phone has no agent spawner to pass it, and the resource API is not on the phone's lane. |
| Pin Workspace / Unpin Workspace | layout tile in `sec_pinned` (`sidebar_layout.update`), legacy `set-workspace-metadata {pinned}` | row menu > **Pin Workspace / Unpin Workspace** | works (parity2) | Pin sends the legacy flag, which the Mac turns into its pinned tile (`migrateLegacyPins`); Unpin removes the tile (`item.remove`). The phone reads the tiles (`sidebar_layout.get`). |
| Set Workspace Color… / Reset Workspace Color | `set-workspace-metadata {color}` | row menu > **Appearance** > the Mac's nine colors (Grey…Orange), **Reset Workspace Color** | works (parity2) | The row shows the color as a bar in its gutter (idle rows). |
| Set Icon… / Remove Icon | `set-workspace-metadata {icon}` | row menu > **Appearance** > **Set Icon…**: a picker of every SF Symbol this iPhone draws, searchable by name and keyword (read at run time from the system's CoreGlyphs bundle, as the Mac's `IconPickerSymbolCatalog` reads its own), or one emoji; **Remove Icon** | works (ws-rows batch; live: `icon` pass) | Was 16 symbols. The Mac's picker also takes uploaded images (asset ids), which a phone cannot upload. The row shows the icon before the name. |
| New Workspace Above / Below / at Top / at Bottom (`WorkspaceVerbActionCatalog`), New Workspace in Group (`workspaceGroup.newWorkspace`) | a new workspace placed at `WorkspaceSlot.above / below / top / bottom` (the sidebar's personal order), or in the group | row menu > **New** > the four places; group header menu > **New Workspace in Group** | works (ws-rows batch; live: `place` pass) | `new-workspace {name}`, then the moves the row menu already sends: `workspace.place` into the anchor's group (or the chosen group), then `set-personal-workspace {index}` beside the row. The new workspace opens on the phone, as New Workspace does. Pinned rows offer only at Top / at Bottom (the Mac orders pinned tiles with a layout move off the lane). At Top goes above every loose row; a group placed at the very top stays above it, since a group's place (`top_index`) is not a phone's to change (`workspace_group.update` refuses it). |
| Merge Workspace Into… | `move-tab-to-workspace` per tab (`WorkspaceStructureHandlers.merge`) | row menu > **Move** > **Merge Workspace Into…** > another workspace of that Mac | works (ws-rows batch; live: `merge` pass) | Every tab the phone lists moves, in order; the emptied workspace goes, as on the Mac. Home never merges and is never a target (`WorkspaceMerge.staysPut`). |
| Sidebar Group ▸ Group by None / Group by Folder (`sidebar.groupBy`) | a Mac setting the sidebar reads | Workspaces toolbar > **View Options** (or **Filter** with several Macs) > **Group** > **Group by None / Group by Folder** | works (ws-rows batch; live: `folder` pass) | The phone's own list: one Mac's loose rows under a header per folder (first-seen order, "No Folder" last, the last path component as the title, as `SidebarFolderTitle`), groups as they are. Kept on this iPhone; the Mac's own `sidebar.groupBy` is a Mac setting the phone does not edit. A list mixing several Macs in the phone's own order is not bucketed, as the Mac groups by folder only with one machine. |
| Move the Workspace to the Top When Its Agent Finishes (`notifications.attention.moveToTopOnAgentFinish`, https://github.com/manaflow-ai/cmux/issues/31513; with `moveToTop`, on every notification) | `set-personal-workspace {index}` (or the sidebar document move) of Move Workspace to Top, run by the Mac when the notification arrives | the moved row, in the Workspaces list | works (follows the Mac's order) | The Mac moves the row in its personal order, and the phone's list follows that order ("Workspace list order" below), so the phone shows the move. The setting itself is a Mac setting, changed in Settings, the palette, `cmux settings set` or MCP; the phone does not edit Mac settings. |
| Move Workspace Above… / Below… (next to a named row: into or out of its group) | the sidebar `.reorder` a row drag sends (personal order, or the sidebar document) | — | missing | The Mac's `workspace.moveAbove` / `moveBelow` (`cmux workspace move-above\|move-below --anchor`, cmux#29907) are its drag as a verb. The phone has no row drag and no anchor picker yet; Move Up / Down, Top / Bottom and Move Workspace to Group reach the same orders in steps. |
| Sidebar view toggles: Workspaces as Tabs, Chrome-Style Groups, Workspaces Side by Side (App Store cards; `sidebar.workspacesAsTabs`, `sidebar.chromeGroups`, `sidebar.sideBySide`) | none: cmux-next.json keys the Mac's own sidebar reads | — | not from a phone | Mac-only chrome: they change how the Mac's sidebar draws and how its rows click and drag onto its panes. The phone's Workspaces list has its own one-line rows and no panes to drop beside; the keys stay settable over `cmux settings` like any setting. |
| App sections drawn from scenes: the customize app kit (`Panel`, `Toggle`, `Slider`, `cmux.toast`, `cmux.theme`; Leo 2026-11-04) | none: the daemon's app supervisor runs the app and streams its scene to the Mac (`apps-scene`) | — | not from a phone | Mac-only chrome: the phone draws no app scenes at all (no `Row`, `Button` or `TextField` either), so it has no renderer to add these nodes to. A phone renderer of app scenes is its own feature; when it comes, these three nodes and `toast.show` come with it. |
| Labs > Live Code (`labs.liveCode`, docs/cmux-next/live-code.md; Leo 2026-11-05) | none: the Mac app interposes Swift patches into its own process | — | not from a phone | Mac-only: it changes the running Mac app's own code from a checkout on that Mac (a live code DEV build, `scripts/live-code/patch.py`). The phone app cannot load code it was not built with, and loading code into the Mac from a phone is not a lane a paired phone may have (SECURITY.md). The key stays settable over `cmux settings` by the person; agents are refused. |
| Clear Workspace Name | `set-workspace-metadata {title: null}` | row menu > **Options** > **Clear Workspace Name** (only when a display name is set) | works (parity2, live: same flow) | The workspace's own name shows again. |
| Edit Workspace Description… | — | — | not on the Mac either | The Mac reports it needs a daemon capability (`workspace-description-v1`) the daemon does not have. |
| Mark Workspace as Read / Unread | `ack-tab-notifications` on unread tabs + `set-workspace-metadata {marked_unread}` | row menu > **Options** > **Mark Workspace as Read / Unread**; opening marks read | works (parity2) | |
| Duplicate Workspace | composed app-side (`WorkspaceStructureHandlers.duplicate`: new workspace, then `WorkspaceBlueprintBuilder` makes each tab with `new-tab {cwd}` or a browser tab) | workspace row menu > **Duplicate Workspace** (not on Home) | works (round 3; live: `duplicate` pass) | No daemon command duplicates a workspace, and `apply-layout` carries `command` per leaf, so it stays off the lane. The phone composes it from lines it already sends: `new-workspace {name}`, then in the new pane `new-tab {pane}` per terminal and `new-browser-tab {url, pane}` per http/https page, and `cd '<folder>' && clear` typed into each new shell (`changeDirectoryLine`, as New Workspace in a folder). No allowlist change and no new spawn path (each shell is the Mac's own New Terminal). Unlike the Mac: every tab goes in one pane (splits and ratios are not copied), agent chats and non-web pages are left out, color and icon are not copied, and the copy is not placed right below the source. |
| New Workspace Group (standalone), Duplicate Workspace Group | `workspace_group.create {name, color, room}`; `workspaceGroup.duplicate` (a new group of the same name with a duplicate of each member) | New Workspace (hold) > **New Workspace Group…** (a name); group header menu > **Duplicate Workspace Group** | works (ws-rows batch; live: `groups` pass) | The new group is empty on the Mac; the list shows it as an empty header whose menu has New Workspace in Group and Delete Group. Duplicate makes the group (same name and color), then each member's Duplicate Workspace into it, in order. **New Subgroup**: not from a phone; `workspace_group.create` from a phone takes no parent group (policy.rs `ALLOWED_RESOURCE_OPERATIONS`), so nesting needs a lane change (#13742). |
| Show Workspace / Tab Resource Usage (`ResourceActionCatalog`) | the app's `resources` control method (each terminal's CPU and memory) | — | not from a phone (yet) | The phone's lane has `machine-usage`, which is a Cloud machine's model spend (tokens and dollars for its `vm_id`, null on a local Mac), not CPU or memory per workspace or tab. The per-terminal numbers are the daemon's `terminal-resources`, which is not on the lane: a lane change for #13742. |
| New WebKit Tab / New Chromium Tab (`TabActionCatalog`) | `new-browser-tab` with the Mac's engine choice | — | not from a phone (yet) | The phone's lane takes `new-browser-tab {url, pane}` only (DaemonLanePolicy fields `cols, pane, rows, url`); no engine field, so the phone's one New Browser Tab stays. A lane change for #13742. |
| Workspace groups | personal groups as `cmux.protocol/2` state operations: `workspace_group.create {name, color, room}`, `workspace_group.update {name \| color \| collapsed}`, `workspace_group.delete`, `workspace.place {workspace, group}` | the list shows each group's header in the Mac's order (tap: **Collapse / Expand Workspace Group**); hold a header for **Rename Group…**, **Set Workspace Group Color…** (the nine colors), **Collapse / Expand Workspace Group**, **Ungroup Workspaces**, **Delete Group** (asks first); a row's menu > **Group** > **Move Workspace to Group…** (the Mac's groups, then **Move Workspace to New Group**) and **Remove Workspace from Group** | works (round 3; live: `groups` pass) | Each change shows at once and comes back if the Mac refuses. A new group takes the Mac's next color and "New Group" when unnamed. Move Workspace Up / Down stays inside the workspace's group. The phone shows only groups of this Mac's workspaces (cmux-mobile-host refuses changes to a group that holds another machine's workspaces) and shows them whatever the Mac window's room. Not on the phone: Move Workspace Group Up / Down, group icon, Pin/Unpin Group, New Workspace in Group, Close All Workspaces in Group (SECURITY.md "Workspace groups"). |
| Remove All Workspace Colors; Collapse Others, Collapse All Groups, Expand All Groups | `set-workspace-metadata {color: null}` per colored workspace; `workspace_group.update {collapsed}` per group | row menu > **Appearance** > **Remove All Workspace Colors**; group header menu > **Options** > the rest (and Remove All Workspace Colors) | works (menu-rows batch; live) | The Mac also sets every group to no color (`GroupTint.none`, wire `none`); the phone's lane takes only the nine palette colors for a group, so group colors stay (a #13742 change would be needed). Collapse Others folds every other group and opens this one (`groupsToggledByCollapsingOthers`). |
| Move to Window / New Window, Show in Finder, Copy Path | app-local | Copy Directory (terminal page) | not applicable | Mac windows and Finder. |

## Terminal

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Type, paste, keys, Ctrl-C | composer, direct typing, key bar, paste | works | |
| Run a command | type it | works | The phone never starts a program by argv (`run` refused). |
| Clear Screen (⇧⌘K) | page menu Clear | works | `clear-history`. |
| Find, Copy | Files and Links, selection | partial | |
| Restart Shell Here | overlay and page menu on a dead terminal | works (round 2) | See Tabs. |
| Reset Terminal, Keep Running After Close | — | not from a phone | Program lifetime stays the Mac's (`set-terminal-keep` not allowlisted). |

## Browser

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Address bar, Back (⌘[), Forward (⌘]), Reload (⌘R) | TabsKit address bar and toolbar | works on a streaming Mac | `browser-navigate` (http/https only), `browser-back`, `browser-forward`, `browser-reload`. Forward right after Back is one tap (finding 5, fixed in parity2 tabs). The address reads the page's host, and a new tab's about:blank reads "Search or enter website" (finding 4). |
| Open Address in New Tab (omnibar) | while editing a browser address: a **New Tab** row with what is typed | works (menu-rows batch; live) | `new-browser-tab {url, pane}` beside the edited tab; the edited tab keeps its page. Through the kit's `editingBackground` hook (CmuxTabsKit unchanged). |
| Open Link in New Tab / Window, Search for (page context menu) | long press on the page > the same rows | works (browser-host batch; live) | The browser host forwards Chromium's `OpenURLFromTab` new tabs (with a user gesture) as `rb.open_tab`; the tab opens beside the page (`new-browser-tab`). The Mac's own remote-tab viewer gets the same tabs. |
| View Page Source (page context menu) | — | needs #13742 | The host opens it as an `rb.open_tab` of `view-source:<address>` (the Mac's remote-tab viewer opens it), but cmux-mobile-host refuses `new-browser-tab` for anything but http and https (`policy.rs`, "a phone may open only http and https pages"), so the phone leaves the row out. Needs: allow `view-source:` of an http(s) address in `new-browser-tab` from a phone. |
| Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G) in a browser tab | page menu **Find…**, ⌘F, ⌘G, ⇧⌘G on a hardware keyboard: the system find bar | works (browser-host batch; live) | `rb.find` / `rb.find.stop`; the Mac's browser finds and highlights, `rb.find.result` gives "2 of 5". Case-insensitive, as Safari's. |
| A page closing its own JavaScript dialog (the iframe that asked is removed) | the alert closes by itself | works (browser-host batch; live) | The host sends `rb.dialog.cancel` when the frame that asked goes away or the tab closes. A page's own navigation while its dialog shows waits for the answer, in Chromium as on the Mac. |
| Hard Reload, Open in Default Browser, Incognito | — | not applicable | |

## Agent chat

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Connect iMessage (Session Info > Connectors): Connect, permission walkthrough, contacts and group chats, Disconnect | — | not from a phone | `chat.db` and Full Disk Access belong to the Mac. The phone’s own Messages app is not readable by cmux; connection and conversation reading stay on the Mac. Every outgoing send still needs the person’s click. |
| Stop | page menu Stop Agent, composer stop | works | `session/cancel`. |
| Retry / Send this prompt again | Retry on a failed turn | works | |
| Retry with another model (`RetryModelMenu.tsx`) | answer's **More** > **Retry with another model** (the chat's models, the current one checked); beside Retry on a failed turn | works (menu-rows batch; live) | `session/set_model`, then the prompt again; a refused model sends nothing. A Claude chat the Mac started refuses the model change (acpmux D13): the chat shows acpmux's own words, "This chat runs with your Mac's Claude permissions. Start a new chat from this device to control it remotely.", and the Mac's chat keeps its model and runs no turn. |
| Switch Model… (⌃⌘M), Mode | composer model and mode menus | works for phone-started chats | A Mac-started Claude session keeps its model and mode from a phone (acpmux D13). Round 2: the mode menus list only modes that ask (Claude's Default and Plan, Codex's Ask) plus the current one, and cmux-mobile-host refuses any other mode a phone sends (`acpmux_policy.rs`), because acpmux lets an authenticated remote connection pick any Codex bridge mode. Round 3 live (`codex_agent_mode` pass, laptop rig): a Codex chat the Mac started (its default Agent mode) put in a workspace tab; a prompt from the phone's chat got "This chat runs in a mode that doesn't ask before each change (agent). Switch it to a mode that asks on the Mac to use it from your iPhone." and the Mac's session got no turn. |
| Continue in… (handoff) | page menu Continue in… | works | `_acpmux/handoff_*`. |
| A github.com pull request link clicked in a chat (or its card's Open) opens the native GitHub page beside the chat: title, state, author, branches, review, checks and changed files from the app's pull request cache, View diff (the diff viewer) and Open on GitHub (`GitHubPageTab`, `GitHubPageProvider`, webviews/src/pages/github; Debug Settings `links.githubNativeViewer`) | — | missing | The Mac reads the pull request with its own `gh` (`AgentReplyPullRequests`) and draws a cmux page; no new trust or policy. The phone opens a link in its browser today. A phone version needs the same pull request read on the Mac served over the link (the card data it already shows for chips) and a native screen for it; follow-up. |
| Dock icon menu: New Chat, New Chat in ▸ (harness, machine), Continue "<last chat>", Unread and Recent chats with More ▸ (`DockMenuController`) | — | not from a phone | Mac-only chrome: the Dock is the Mac's. The phone already starts a chat and opens any chat from its chat list. |
| Allow Once / Allow for This Chat / Deny | permission cards | works | Allow needs the phone's Face ID signature (pairing). |
| A tagged ask at the end of a turn (`[taste]`, `[outward]`, `[irreversible]`, `[physical]`, `[for you]`) as a card with answer buttons (`NextStepCard.tsx`, `nextStepAsk.ts`) | — | missing | The Mac's agent pane reads one tagged question with a 2-4 item list (or a yes-or-no question: Yes, Not now) from a finished turn's answer and draws its answers as buttons; a click sends the answer as the next prompt (`chat.send`), and a later prompt folds the card to the question and the answer. The phone shows the tagged line as prose; a phone version needs the same reading over the transcript it already draws, and a send of the answer as a prompt, which it can already do. |
| The agent's wrap-up box at the end of a turn: acpmux's `wrap_up` tool (`acpmux_mcp_wrap_up.rs`) as the next-step card with a recap and, when the turn leaves a decision, a question with one or two answer buttons (`wrapUp.ts`, `NextStepCard.tsx`) | — | missing | Every chat's acpmux MCP server lists `wrap_up` and tells the agent to call it last. The Mac's agent pane reads the call's typed input from the transcript, drops the call's row and draws the box under the answer; a click sends the answer as the next prompt (`chat.send`). The phone shows the call as a tool row; a phone version needs the same reading of the call it already receives, and a send of the answer as a prompt, which it can already do. |
| Queue: Edit queued prompt / Send now / Move up / Move down / Remove queued prompt | hold a queued prompt (the agent pane's wording) | works (round 3; live: `queue` pass) | acpmux `_acpmux/queue_edit {op: update \| send_now \| move}`, `_acpmux/queue_remove`; the phone follows `queue_updated` and `queue_order`, which it now asks for by name (acpmux left them out of `transcript`, so Move up and Edit changed the Mac but not the phone; fixed both sides in round 3). hostd lets `_acpmux/queue_edit` through only when the session's current mode asks. Live: two prompts queued behind an approved 90 s command; Move up 0.3 s, Edit 0.3 s, Send now 0.5 s (steered), each read back in the Mac's queue; both answered. Resume (after an error) is not on the phone. |
| Fork (chat menu "Fork"; palette Fork Conversation to New Tab) | page menu **Fork** | works (parity2 tabs; live) | acpmux `session/fork` (the whole chat), then `new-conversation-tab` of the copy in the chat's pane; the copy comes to the front, as the Mac opens a fork in a tab of its own. A Claude chat the Mac started is refused for a remote connection (acpmux D13, `remote_guard.rs`); the phone shows acpmux's own reason: "This chat runs with <Mac>'s Claude permissions. Start a new chat from this device to control it remotely." Fork from an earlier turn (Fork from here) is not on the phone. |
| Archive (chat menu "Archive", Archive Chat ⌃⌘A) | page menu **Archive** | works (parity2 tabs; live) | acpmux `_acpmux/archive {archived: true}`, then `close-surface`, as the Mac's pane asks its app to close the tab. Unarchive is on the Mac (its archived list). |
| Composer Select All covers attachments; Copy / Cut carry them (`composer.copy`) | — | missing | The Mac's composer selects its attachment chips with the text; Copy and Cut put the text, then each attachment as a file, on the pasteboard (AgentPaneComposerCopy.swift), and a paste into a cmux composer puts both back in order (composerCopy.ts). Follow-up: the phone composer's copy of attachments. |
| Composer emoji by shortcode: `:` and two letters list emoji (`:tedd` → 🧸), a text emoticon lists its face (`:DD` → 😆) | — | missing | The Mac's composer lists matches in a menu over the typed `:` (emojiShortcodes.ts, EmojiMenu.tsx); the iPhone keyboard has its own emoji keys and search. Follow-up: the phone composer's shortcode completion. |
| Composer usage ring: right-click Context Usage / Plan Usage / Hide Usage Ring; in plan mode the 5-hour and weekly limits popover (`PlanUsageCard.tsx`, `agentPane.composerRing`), and Session Info Usage's Plan limits rows | — | missing | The Mac reads acpmux's session detail `usageLimits` (Claude Code's `rate_limit_event`, Codex's `account/rateLimits/updated`); the phone gets the same detail over the link, so showing it needs no new trust or policy. The phone has no composer ring yet to put it on; a read-only Plan limits row in its chat info is the natural first step. |
| Tuck away the running tray over the composer: the tray's chevron at its top middle, the composer's pull tab that brings it back, Settings > Agent Chat > Tuck Away Running Tray (`agentPane.display.trayTucked`; `TrayPullTab.tsx`) | — | missing | The phone's chat draws no running tray over its composer (no subagent, command or plan bar), so it has nothing to tuck; this row goes with that tray when the phone gets it. The setting itself is a Mac cmux-next.json key. |
| Checkpoints, Commit, Push | Checkpoints shown as unavailable | missing | The link carries no checkpoints. |
| Trust this folder ("Trust / Don't trust") | the toast says how, step by step; `claude` in the terminal works | partial | acpmux refuses `acp.trust.set` from a remote connection (finding 2). The phone now says: "Claude hasn't been trusted in <folder> yet. Either: 1. On the Mac, open this workspace in cmux and choose Trust when it asks. Or 2. Here, open this workspace's terminal, type claude, press Return, choose "Yes, I trust this folder", then type /exit. Then start the chat again." Whether a Face ID answer from the phone may count is the person's decision (#13742). |

## Chief and the Feed

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Chief conversation, questions | Home > Chief | works | Answers need the phone's signature. |
| Stop the Chief, Chief settings | Chief settings | works | `chief.stop`, `chief.engine.*`. |
| New Chief…, Archive Chief, Memory Inspector | — | missing | |
| Chief teleport: the location chip (This Mac, cmux Cloud, a host) beside the Chief's name and in the Chief card, its Teleport menu (`chief.moveTo`), Roll Back (`chief.moveRollback`), and Home following the moved Chief | — | not from a phone | A move runs `cmux chief move` on the Mac: it drains and stops the Mac's Chief host, copies its home over the Mac's own SSH keys, and signs in to cmux Cloud with the Mac's session. A paired phone may not run local commands or reach SSH hosts through the Mac (SECURITY.md, "Remote CLI relay"), and a move started from the phone would cut the Chief it talks through. The phone already follows where the Chief answers: a Chief moved to cmux Cloud is the account's hosted Chief, which the phone's Home lists. A read-only location line would need the Mac's `state/moved.json` on the lane; not added. |
| Chief imports browser cookies on request (`cmux browser import-cookies` from the Chief's shell, https://github.com/manaflow-ai/cmux/issues/32960) | Home > Chief: ask the Chief | partial | The request can come from the phone's Chief chat, but the consent panel opens on the Mac and the Mac's Keychain prompt follows Allow. The other browser's cookies live on that Mac, so only someone at the Mac may allow reading them; no phone-side Allow. |
| Cloud desktop, **Open Desktop** (the Cloud machine's screen) | Chief info > **Computer** (`chief.settings.computer`) | partial | View only, by design: hostd drops touches, text, keys and buttons for the `c~<machine_id>~<team_id>` `surface` key, and the card sends none. Shown only when the Mac's `cloud-directory` says `paid` and a machine `ran`; the first running machine, else the first that ran. Paused or pausing: "Computer is asleep"; starting or provisioning: "Waking up…"; else "Computer isn't available". Needs `cloud-desktop-v1` for the live screen (https://github.com/manaflow-ai/cmux/issues/31488). code-checked; live pending |
| Show Feed, Mark read | Feed tab, swipe | works | |
| Jump to Latest Unread (⇧⌘U), Jump to Last Prompt (⌃⌘B) | Command Palette > **Jump to Latest Unread**, **Jump to Last Prompt** | works (palette batch; live) | Read from what the phone already gets: the tree's unread markers (`created_at_ms`, newest first) and `agent-changed` (a turn the person prompted starts, the Mac's `AgentRoster.startsPromptedTurn`), across the active team's Macs. Like the Mac's, Last Prompt covers the agents in the daemon's roster (terminal agents reporting through `report-agent`); an acpmux chat tab reports nothing there, on the Mac too. No new command. "There are no unread notifications." / "No agent has been given a prompt yet." as on the Mac. |
| Mute Chat Notifications (`agentChat.toggleNotificationMute`) | chat page menu > **Mute Chat Notifications** / **Unmute Chat Notifications** (and the palette) | partial (palette batch; live) | Phone-local, like the Feed's per-workspace mute: the Mac's mute is an acpmux tag the lane does not carry. A muted chat's pushes arrive quietly on this phone only (the service extension makes them passive with no sound; in front, Notification Center only, no banner). The list is in the push keychain group (`PushChatMutes`), shared with the extension. |
| Clear All Notifications | Feed > Filter menu > **Clear All Notifications** | works (parity2) | `notification.clear` on the Mac's current session (new on the lane, see SECURITY.md); the Feed's terminal events go with it. No confirmation, as on the Mac. |
| Mute workspace | Feed > Filter > Workspaces toggles | partial | The phone's mute is the phone's own (the Mac's mute is not on the lane). |

## Navigation and search (palette batch, cmux#25834)

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Command Palette… (⇧⌘P; `WindowActionCatalog`, `CmuxNextPalette`) | page menu > **Command Palette…**, hardware ⇧⌘P, and ⌘K except on a terminal page (where ⌘K stays Ghostty's Clear Screen) | works (palette batch; live) | A sheet with a search field (HIG Sheets, Search fields). Its rows are the page menu's and card menu's own items for the tab on screen (`pageMenu`, `cardMenu`), the + menu's options, Search Tabs and the jumps: no second action list. A picked row runs once the sheet is gone. |
| Search Tabs… (`tab.search`) | palette > **Search Tabs…** (every tab), any palette query, and the browser address bar's **Other Workspaces** | works (palette batch; live) | Every workspace of the active team's Macs, this one first; a tab elsewhere opens its workspace on that tab. TabsKit's own Switch to Tab stays this workspace's. |
| New Tab from Text (`newTab.submit`) | palette: type, then **Open in New Tab**, **New Terminal**, **Ask in New Agent Chat** or **Search the Web** | works (palette batch; live) | The Mac's table (`NewTabIntent`): `!` first is a terminal with the command typed and not run, an address a browser tab beside the tab on screen (`new-browser-tab {url, pane}`), other text a new agent chat that sends it; web search is its own row. |
| Open Link… (`link.open`), `cmux://` links | palette: a pasted cmux link > **Open Link**; links tapped in chats, Chief and the Feed; links from other apps | works (palette batch; live) | Routing landed with verify/deep-links.md; this batch adds Open Link in the palette and verified a Chief message's link live. |

## Mac Screen

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| View another Mac's screen (Mac Screen tab, streamed on cmux.rd/1) | the Screen Sharing viewer (CmuxMobileScreenSharing) | partial | The phone views over WebRTC. A Mac host takes its protocol from the viewer's offer: a cmux.rd/1 document runs `cmux rd serve`, any other offer runs ScreenStreamHost, so Macs and phones both reach it. The phone has no cmux.rd/1 link yet: iOS cannot start the Mac's helper process, so the link has to come in as a library. code-checked; live pending |
| Share This Mac (serve a session) | | not from a phone | A phone views Macs; it is not a screen host. |

## Workspace list order (parity2 decision)

The phone's Workspaces list follows the Mac's sidebar: **Needs You** first (the
phone's own attention section; those rows are also in the Mac's list), then
**Pinned** in the Mac's tile order, then the rest titled **Workspaces** in the
Mac's order: the person's personal order (`list-personal`) on a Mac that has
one, else the daemon's workspace order. Rows of a Mac whose order the phone
does not know yet (cached, mock) keep the old newest-activity order under
**Recent**. Move Up / Down moves within the row's section on its Mac.

## Live run, workspace lane (parity2, 2026-10-15)

Rig Mac `cmux-mobile-p2-26459378` on mini-cmux11s, the phone in one headless simulator
(`cmux-mobile-p2-ws`), driver `verify/parity/pq_ws.py`; the Mac side read from its own
daemon (list-workspaces, list-personal, sidebar_layout.get, list-notifications).
Videos: `~/cmux-next-ios-e2e/p2ws-raw/ws-<flow>.mp4` (not committed).

| Flow | Result |
| --- | --- |
| `pin_color_order`: Pin, Set Workspace Color… Green, Reset, Unpin, Move Up, Move Down | Pass: pinned tile on the Mac, color `green` then cleared, unpinned; Move Up changed the Mac's personal order `[c, b, a]` to `[b, c, a]` and the phone list matched; Move Down restored it |
| `mark_unread`: Options › Mark Workspace as Unread, then as Read | Pass: `marked_unread` true, then false |
| `bulk_close`: Close › Close Workspaces Below (after "Close 2 workspaces?") | Pass: exactly the two named workspaces closed, the chosen one stayed |
| `open_folder`: New Workspace › Open Folder… `~/cmux-next-ios-e2e/p2ws-folder` | Pass: the workspace on the Mac in 0.7 s, its terminal in that folder |
| `feed_clear_all`: Feed › Filter › Clear All Notifications | Pass: the Mac's notification ledger empty |
| `trust_steps`: New Agent Chat in a folder Claude was never trusted in | Pass: the step-by-step message in 1.6 s |
| `icon_clear_name` (rig `cmux-mobile-p2-d1a70bd6`): Appearance › Set Icon… hammer, Remove Icon, Options › Clear Workspace Name | Pass: `icon` hammer then cleared on the Mac, the row showed the icon; the display name cleared and the own name came back |
| `agent_chat_workspace`: New Workspace › New Agent Chat › p2ws-proj | Pass: a new workspace on the Mac whose only tab is the chat (`conversation`), in 2.1 s |
| `queue_edit`: a second prompt while a turn runs, then Edit queued prompt and Send now | Not shown: the second prompt was taken into the running turn (answered at once), so nothing queued; the flow could not reach the queue menu. An earlier attempt hit "API Error: Output blocked by content filtering policy" on a long numbered list |

## Live run (2026-10-14/15)

- **Mac:** a real tagged cmux-next build of this branch (`cmux-mobile-e2e-dc79f937`, fleet job
  `632570e0c07656235e782c58`, with `feat-cnx-ios` 3d2a8581: the browser host fix and
  the media lane) on `mini-cmux11s-mac-mini`, hidden, launched with `open --env`
  only (no bundle edit, `verify/parity/rmac.py`). Agents reach Claude through the
  team subrouter server (real model calls).
- **Phone:** this branch's Demo build in one headless simulator (`cmux-mobile-parity-1`)
  on the laptop, over the real link (TeamHub signaling, WebRTC direct). Taps and
  typing are HID events (`axe`); driver `verify/parity/pq.py`.
- **Videos:** `~/cmux-next-ios-e2e/parity-raw/*.mp4` (not committed).

| Flow | Result | Video |
| --- | --- | --- |
| New Agent Chat (Mac default `claude`, Opus 5.5) in a workspace folder | Pass after fixes: chat open in 3-12 s, "PONG" in 42 s; Mac lists the session (`claude`, `claude-opus-5-5`, policy `ask`, the workspace folder) | `agent-default.mp4` |
| New Agent Chat With… (sheet: Harness, Model; Codex rows "Unavailable" with the Mac's reason) | Pass: loads in 0.8 s; Claude Code + Claude Haiku 5.5: open 3.1 s, "PONG" 3.6 s; Mac session `claude-haiku-5-5` | `agent-chooser.mp4`, `agent-chooser-model.mp4` |
| Another harness: `cmux` (open-source model through the cmux model router) | Opens (session `cmux`, `qwen/qwen3.7-flash`), then Working with no reply for 2.5 min: see finding 3 | `agent-chooser.mp4` |
| New Browser Tab, address bar, navigate, Back, Forward, Reload | Pass: example.com and iana.org render; Back, Forward (second tap; see finding 5), Reload | `browser.mp4`, `browser-forward.mp4`, `browser-reload.mp4` |
| New Terminal | Pass: opens in the workspace folder in 5 s; `echo parity-$((6*7))` prints `parity-42` | `terminal.mp4` |
| New Workspace > Recent Directories > proj | Pass: `proj` on the Mac in 1 s, terminal at `proj %` (cd + clear) | `workspace-folder.mp4` |
| New Workspace (tap), then New Agent Chat in it | Pass at the time (the tap then reused the last folder; after review a tap opens at the Mac's default folder, as on the Mac) | `workspace-home-agent.mp4` |
| Rename Tab… (card menu) | Pass on the Mac (`rename-surface`); the field then started with the old name and the typed text landed mid-name, so it now starts empty | `tab-edits.mp4` |
| Duplicate Tab | Pass: Mac tabs 12 -> 13, the copy opens | `tab-edits.mp4` |
| Drag to reorder | Unit-tested only: the simulated drag opened the card menu, then left the workspace | — |
| A new folder's trust question | Refused by acpmux (`trust.pending`) until answered; answered from the phone by running `claude` in the workspace's terminal and choosing "Yes, I trust this folder" | `trust-from-phone-terminal.mp4` |

### Findings

1. **Fixed: acpmux replies over 16 KiB never reached the phone.** cmux-mobile-link writes
   in 16 KiB chunks since the input lane (e1eb3562), and
   `AcpmuxConnection.MessageJoiner` dropped any chunk under 256 KiB that did not
   parse, so `_acpmux/models` (23 KB) never answered and New Agent Chat sat on
   "Opening…". Transcripts and event pages over 16 KiB were lost the same way.
   Fixed with a red/green test (`sixteenKiBChunksJoin`), also on `feat-cnx-ios`.
   The catalog reads now give up after 15 s.
2. **A new folder's trust question needs the Mac (or the terminal).** acpmux
   refuses `acp.trust.set` from a remote connection, so a phone cannot answer
   "Trust / Don't trust". The phone now says so ("Trust proj on <Mac> first:
   answer its trust question in cmux on the Mac, or run claude in this
   workspace's terminal and accept it."). Answering it on the phone with the
   phone's Face ID signature is a trust decision for #13742.
3. **Harnesses whose API is behind a loopback proxy hang when a phone starts
   them.** acpmux runs a phone-started Claude in its remote-chain Seatbelt
   profile, which shuts loopback except Claude's own `ANTHROPIC_BASE_URL` port.
   The `cmux` harness (the cmux model router through the local relay) and
   `claude-sr` (`sr claude proxy`) reach their APIs another way: `cmux` worked
   and never answered; `claude-sr` closed ("agent process closed"); `claude`
   through a loopback `ANTHROPIC_BASE_URL` failed with "Unable to connect to API
   (EPERM)". Owner: acpmux remote sandbox (`hub/remote_sandbox.rs`).
4. Fixed (parity2 tabs): the streamed browser tab's address control read "Address,
   about:blank" to VoiceOver after navigation. The Mac's browser reports the old page
   (a new tab's about:blank) while a navigation loads, and that report replaced the
   address the person typed. The model now keeps the asked-for address until the page
   reports another one or stops loading, and an about:blank tab reads "Search or enter
   website". Unit tests `theAddressIsTheOneAskedForWhileItLoads`, `aBlankBrowserTabHasNoAddress`.
5. Fixed (parity2 tabs): Forward once did nothing on the first tap right after Back.
   The browser reports the old history (no forward entry) until Back commits, so the
   button was disabled, or the Mac ignored the step. Back now offers Forward at once,
   and a step tapped before the previous one commits is sent when it does (bounded at
   2 s). Unit tests `forwardRightAfterBackNeedsOneTap`, `aCachedStepCommitsOnTheNewAddress`.

### Review (correctness-first subagent, 2026-10-15)

Fixed on this branch (52e2b628 and after): the typed `cd` refused folders with
line-editing characters (DEL, ^U, ESC, a backslash, `!`) after an injection
finding; `move-tab` sent the target's index (off by one forward, and could move a
tab into another pane); `session/new` and `set_model` had no timeout; the
folder refusal blamed an old Mac; the joiner re-parsed large messages on every
chunk; a renamed Codex profile showed as startable; a plain New Workspace tap
typed `cd` to the last folder; the Mac kept the folder list after iPhone
connections turned off when no approvers were paired. Those fixes have unit
tests and were not driven live again.

## Parity round 2: tabs lane (2026-10-15)

Branch `feat-cnx-ios-p2tabs`. No daemon allowlist change: every command used was already
allowed (`move-tab-to-workspace`, `move-tab-to-new-workspace`, `set-tab-pinned`, the
`*-tab-group*` commands, `new-conversation-tab`, `close-surface`). acpmux's Fork and
Archive go over the phone's acpmux lane as a remote (Web) connection: `session/fork`
passes `remote_guard.rs` (folder and policy checks, D13 refusal for a Mac-started
Claude chat) and `_acpmux/archive` sets one tag.

Phone menus, following the Mac's tab menu (`ContextMenuEssentials`): the card menu has the
top rows (Rename Tab…, Pin Tab / Unpin Tab, Duplicate Tab) and the group rows; TabsKit adds
Close Tab and Close Other Tabs. The page menu adds the Mac's More rows that make sense on a
phone (Move Tab to Workspace…, Move Tab to New Workspace), and on an agent chat the chat
menu's Fork and Archive.

Live run (2026-10-15, rig Mac `cmux-mobile-p2-1585ab34` on mini-cmux11s, the Debug app of this
branch in one headless simulator `cmux-mobile-p2-tabs`): `verify/parity/pq_tabs.py`, each flow
checked on the Mac's own daemon tree (its socket) and recorded in `~/cmux-next-ios-e2e/p2tabs-raw/`.

| Flow | Result | Video |
| --- | --- | --- |
| Pin Tab, Unpin Tab (card menu) | Pass: pinned on the Mac in 0.2 s and first in its pane; unpinned in 0.2 s | `pin.mp4` |
| Move Tab to Workspace… (page menu, picker) | Pass: the tab in the other workspace 0.1 s after the pick | `move-to-workspace.mp4` |
| Move Tab to New Workspace | Pass: a new Mac workspace named `p2tabs-t2` (the tab's name) holds it | `move-to-new-workspace.mp4` |
| New Tab Group, Add Tab to Group… | Pass: both tabs in one Mac group (red), each step 0.1 s | `tab-groups.mp4` |
| Rename Tab Group…, Pin Group, Ungroup Tabs | Pass: renamed in 0.8 s (the alert capitalizes the first letter, as iOS text fields do), saved, ungrouped | `tab-groups-2.mp4` |
| Drag to reorder (XCUITest long press and drag) | Pass: Mac pane order [95, 98, 100] -> [98, 100, 95] | `reorder.mp4` |
| Browser: address, Back, Forward right after Back | Pass: the address reads "Address, iana.org" (never about:blank); Back then Forward 0.5 s later lands with one tap. The daemon's tab record of a streamed tab keeps about:blank (the page's address comes from the Mac's browser host) | `browser-forward.mp4` |
| New Agent Chat, then Fork, Duplicate Tab, Archive (page menu) | Pass: a real turn ("PONG"); Fork made a chat tab with its own session in 0.8 s and its transcript; Duplicate Tab a third tab on the same session; Archive closed a tab on the Mac | `chat-fork-duplicate-archive.mp4` |

Not driven live: the D13 refusal of a fork of a Mac-started Claude chat (unit-tested,
its text is acpmux's). Home: a tab in the Mac's Home workspace (daemon `kind: "home"`) has no Move Tab to New
Workspace on the phone, and a request is refused with "Home's tabs stay in Home." (the Mac's
`TabPromotion`); Move Tab to Workspace… stays, as on the Mac. Unit-tested
(`homeTabsStayInHome`), not driven live.

## Round 2 (2026-10-15, branch `feat-cnx-ios-parity2`)

Rig: real cmux-next builds of this branch (`cmux-mobile-p2-bfdcd53e`, then `cmux-mobile-p2-26459378`),
hidden, settings by `open --env` only. Agents through the team subrouter on
mini-cmux11s (`~/cmux-next-ios-e2e/p2`); Codex on a hidden rig app on the laptop
(`~/cmux-next-ios-e2e/p2l`), with the laptop's own Codex login used in place (quit after).
Phone: this branch's Demo build in one headless simulator, real link. Videos:
`~/cmux-next-ios-e2e/p2main-raw/` (orchestrator), `p2ws-raw/`, `p2tabs-raw/` (lanes).

| Flow | Result | Video |
| --- | --- | --- |
| Codex: New Agent Chat With… > Codex > Start Chat, "PONG" | Pass: open 4.7 s, reply 9.7 s; Mac session `codex`, mode `ask`, policy `ask`, model gpt-6.1-sol | `codex-agent.mp4` |
| Codex tool approval: "echo hi > p2-approval.txt" | Pass: Codex asked first ("Codex wants to run a command"), Allow + Face ID (simulator match) on the phone, the file appeared on the Mac | `codex-approval.mp4` |
| Codex again on the final build (`cmux-mobile-p2-d1a70bd6`, with hostd's current-mode check on every prompt) | Pass: open 4.6 s, "PONG" 13.2 s | `codex-final.mp4` |
| `claude-sr` (sr claude proxy) | Pass (was "agent process closed"): open 4.5 s, "PONG" 3.9 s | `sr-agent.mp4` |
| `claude` (user settings route to the subrouter) | Pass: "PONG" 1.9 s | `claude-agent.mp4` |
| Restart Shell Here (rig `cmux-mobile-p2-1585ab34`; the rig killed the tab's terminal host until the Mac stopped respawning it, as "Terminal stopped: its host kept failing") | Pass: the phone showed "The shell ended." with Restart Shell Here; one tap, the Mac listed the tab live in 0.1 s with a new shell (pid 55406 -> 55788), whose parent is the rig app's own `cmux-tui __terminal-host` on the Mac; the page reattached and `echo restarted-$((6*7))` printed `restarted-42` | `restart-shell.mp4` |
| `cmux` (local relay to the cmux model router) | The request now reaches the relay from the sandbox (was: Working, no reply). The hosted router answered 403 "this team cannot use the model router on this deployment yet" for the test account: an account entitlement, not the phone path. On mini-cmux11s the rig's local router did not answer its admin socket (a Mac-side router problem; a Mac-local session failed the same way). | `cmux-agent.mp4` |

Findings fixed in round 2:

1. **Codex refused from a phone.** acpmux already bridged Codex through `codex
   app-server` and let an authenticated remote connection use any of its modes,
   but a remote session stayed in the bridge's default `agent` (no asking) and the
   phone refused the family by name. Now: a phone-started Codex chat starts in
   `ask`, the catalog says so, and hostd keeps the phone to asking modes.
2. **Agents behind a local model proxy never answered.** Claude Code applies its
   user settings `env` over its process env, so the route the sandbox opened
   (the profile's) was not the one Claude used (the user's settings pointed at the
   subrouter, a port the sandbox kept shut: EPERM or a silent hang). The sandbox
   now opens exactly the endpoint Claude will use, pins it in the inline
   settings, and skips the user settings source when the profile names its own
   route (whose key the user settings would replace). `sr claude proxy` cannot
   listen in the sandbox, so a remote chain runs Claude straight to the
   subrouter server, as acpmux already does when that launcher cannot run.
   Tests: unit (Linux) and `remote_sandbox` on macOS (the chain reaches its
   loopback proxy port and no other loopback port).


### Remaining gaps after round 2 (and why)

- **opencode** from a phone: refused (re-checked in round 3, below).
- **`cmux` harness** (cmux model router): the phone path works through the sandbox now;
  the test account's team is not entitled to the hosted router (403), and the
  mini-cmux11s rig's local router did not answer. Needs an entitled account to see a reply.
- **Folder trust from the phone**: left on the Mac by decision; the phone gives the steps.
- **Duplicate Workspace**: built in round 3 from lines the phone already sends (below).
- **Workspace groups** (personal order): done in round 3 (see the Workspaces table; live pending).
- **Reopen Saved Tab Group**: built in round 3; live check pending (below).
- **Open Link in New Tab, Checkpoints, Commit, Push, New Chief…, Memory Inspector, Reset
  Terminal, Keep Running After Close**: not on the link (or Mac-only by design).
- **The Mac's last pick** reaching the phone: unit-tested on both sides; not driven live
  (a hidden rig app has no person to pick on its New Tab page).
- **A Mac-started Codex chat in Agent mode** is refused for phone prompts by cmux-mobile-host
  (unit-tested); not driven live.

## Round 3 sweep (2026-10-15, branch `feat-cnx-ios-p3sweep`)

Code-level comparison of the phone with the cmux-next Mac app beyond workspaces and
tabs, with the fixes made on this branch. Every row is **code-checked; live pending**:
the orchestrator drives the steps below and finalizes the state. Mac sources: the agent
pane (`webviews/src/agent-session/acpmux`, strings from `generated/strings.json`), the
Chief settings and Home in `Packages/macOS/CmuxNext`, acpmux and the relay in `cmux-tui`.

Commits: phone `5ccaa08c` (failure copy, retries), `0e81e2ce` (permissions),
`b1aa7008` (diffs, artifacts), `e9e4bb97` (teams, devices), `c4403fc3` (read timeout);
Mac-side `f3ff65e0` (relay). Tests: CmuxMobileKit `swift test` on mini-cmux11s (TurnFailureCopyTests,
TurnFailureLiveTests, PermissionRound3Tests, Round3DiffArtifactTests, plus AgentChatTests,
DiffLayoutTests, DiffViewedStoreTests, FeedPendingTests, ChatFeedRoundOneTests, ParityTests,
FeedRefreshTests, FeedReadMarksTests, AcpmuxParityTests: 120 pass); iOS compile of the
CmuxMobileShell scheme (generic iOS Simulator, Xcode 27) succeeded; Rust `cmux-coderouter`
test, fmt and clippy on rbx.

### 1. Files and artifacts

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Files" (`header.files`): a folder split of the workspace | title menu or More > **Files and Artifacts** (chips All / Files / Folders / Images / Videos / Documents / Code / Links; Grid / List) | partial (different design) | The Mac has no list of what a session touched; the phone builds one from the transcript (edits, reads, tool input and output, attachments, links) and reads bytes over the link's `file` service (24 MB cap). Folders say "Folder listings aren't available…". No "Search files". code-checked; live pending |
| "Document preview" (HTML, SVG, Markdown from a reply; "Preview" / "Code", versions, "Save") | Preview / Source toggle, More: Copy Path, Copy Contents, Share | partial | No versions or Save on the phone; a document that only came in a reply (not a file) is not offered. Fixed: SVG previews as markup (was "Not an image"). code-checked; live pending |
| "Image too large to show" | "This file is larger than 24 MB, too large to preview on the phone." | works | code-checked; live pending |
| (no Mac equivalent) a read that stalls | "Can't open this file" with Try Again | works (fixed) | A read with no bytes for 20 s now gives up ("<Mac> stopped sending this file…"); it used to spin forever if the Mac slept mid-read. code-checked; live pending |

### 2. Diff viewer

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Changes: Last turn" (the transcript's tool diffs, one per edit, pending edits skipped) | **Changes · This turn** card, **Agent Edits** ("Edits in this chat") | works (fixed) | Same source of truth for this scope: acpmux tool-call diffs. Fixed: a file edited twice compared the first snippet's old text with the last one's new text (a wrong diff), numbered lines from 1, and Agent Edits kept only the last turn's version of a file; each snippet edit is now its own hunk without line numbers, a written-then-edited file shows as written, and edits waiting on a permission or refused are left out. code-checked; live pending |
| "Uncommitted / Staged / Unstaged / Committed / Branch" (`git.diff`, `git.status`, `git.checkpoint.diff` through cmux-git) | — | missing | The phone makes no `git.*` calls: shell-made edits and edits older than the loaded history are not on the phone. Needs a read-only git diff on the phone's lane (hostd allowlist, a #13742 decision). |
| "Changed files", "File tree", "Filter files…" | flat list, "N files changed", "N of M viewed" | partial | No tree or filter. |
| "Mark {path} as viewed" | **Mark as viewed** / **Viewed** | works | code-checked; live pending |
| "Switch to split diff" / "Switch to unified diff", "Word wrap" | **Diff options**: Unified / Split, Wrap, Hide Whitespace | works (fixed) | Word-level marks on both (`intraline.ts`, `WordDiff.mark`). Fixed: Hide Whitespace after Expand could index past the end. code-checked; live pending |
| "New" / "Deleted" badges, renames, "Binary file not shown", untracked skipped | A / M badges | partial | ACP diffs carry no delete, rename or binary; those come with git scopes. |
| "Stage", "Unstage", "Create PR", "Undo", "Open in editor" | Copy Path, Copy Line, Copy with Line Number | not from a phone | Read-only on the phone. |

### 3. Chief

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Chief conversation | Home > Chief | works | code-checked; live pending |
| Chief Settings "Harness" / "Model" / "Effort" (`chief.engine.set`) | Chief settings **Harness**, **Model**, **Effort** | works | Same params; on hostd's list and forwarded by the daemon. code-checked; live pending |
| "Stop the Chief" (`chief.stop`) | **Stop Chief** (while Chief is typing) | works | Wording differs a little. code-checked; live pending |
| "Recent replies, answered by:" | **Recent Turns** | works | Wording differs. |
| "Name" | **Name** | works | code-checked; live pending |
| "Avatar" | (hidden) | not from a phone | The phone shows its editor only when `chief.engine.get` reports `avatarSupported`, which no daemon sends, and hostd refuses `avatar`. Left hidden. |
| Answer a Chief question (`conversation-op question.answer`) | **Answer** > sheet > **Send Answer** (Face ID) | works | Signed `cmux-mobile-chief-answer-v1` approval, checked and stripped by hostd. Failures say why ("Not sent: Face ID was cancelled.", "Chief no longer needs this answer.", "Couldn't confirm. Chief may have it." + Check). code-checked; live pending |
| Skip a Chief question | — | missing | The phone has no decline for a Chief question. |
| "Open traces", "Show memory", New Chief…, Archive Chief | text: "Chief's memory and traces open on the Mac." | not from a phone | |
| Cloud desktop / "Open Desktop" | Chief info > **Computer** (live screen, view only; asleep, waking or unavailable states) | partial | View only: no input reaches the machine from the phone. code-checked; live pending |

### 4. Feed: questions and permissions

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Allow once" | Feed **Allow once** (Face ID), chat bar **Allow once** | works (fixed wording) | Signed `approverDecision` after Face ID. Was "Allow" / acpmux's option name. code-checked; live pending |
| "Allow for this chat" | — | not from a phone (fixed) | acpmux refuses every lasting grant from a paired device (`remote.lasting_grant_refused`). The phone offered "Always" / "Allow for this session", which cost a Face ID and then failed; it now offers only Allow once and Deny. Answering it from the phone is a #13742 decision. |
| "Deny" | **Deny**, full swipe | works | Unsigned, at once. code-checked; live pending |
| Question "Submit" / "Skip" | QuestionCard **Answer**; **Decline** after an error | partial | Same `permissionId` from the Feed and the chat. Wording differs; the answer shows before Face ID (rolled back on failure). |
| Answered on the Mac first | card closes "Already answered on your Mac" | works (fixed) | Was: the card reopened with "no pending permission perm_…". With two open asks, one answered on the Mac still shows live until tapped (the session's change notice carries no permission id). |
| "Answered by {name} on {device}" | "Answered" | partial | No attribution on the phone. |

### 5. Settings

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Settings > Mobile > "Phones" > "Remove" (drops links, forgets the pairing) | Settings > **Devices** > Phones row: swipe **Remove** / **Remove iPhone** | partial | The phone removes it from the account's devices only; each Mac keeps allowing it (paired list, Face ID approvers) until removed there. Fixed: the alert now says so. Revoking from the phone needs a Mac-side change (the hub telling hostd a phone was removed) and a #13742 decision. code-checked; live pending |
| Mac removed from the account | Macs row **Remove Mac** | works | hostd stops (4002); the phone forgets the pin. code-checked; live pending |
| (revoke this phone) | **Remove This iPhone from My Macs** | partial | Unpairs only on the Mac linked now; errors are ignored. |
| Settings > Mobile "Status" | Settings > **Transport** | works | Phone-only setting. |
| Notification kinds | Settings > **Notifications**: Questions and permissions, Finished tasks, Errors | works | Match the push kinds. |
| Settings > General > "Retry After Errors" (`agents.autoRetry.enabled`, `intervalSeconds`, `attempts`) | (none) | partial | The loop runs in the Mac's acpmux, so a chat started or watched from the phone retries the same way, and the error card's Retry works there. The three keys are edited on the Mac (Settings, the palette, `cmux settings set`), like Sub-sessions; the phone has no editor for them. |

### 6. Team switching

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Team Picker (⌥⇧⌘T), "Choose a Team" | hamburger **Teams** > a team row | works (fixed) | Macs, link, presence, workspaces and Chief reload. Fixed: the Feed kept the old team's items (an old ask answered went to the new team's Mac); it now empties on a team change and refills from the new team's Macs. A switch by tap or by following a Mac closes an open workspace and a chat opened from the Feed. code-checked; live pending |
| — | Teams row menu: Change color and icon, Invite to team, Copy team name; **Add team** | works | |

### 7. The `cmux` harness and the model service's 403

From code: Claude Code does not retry a 403, so its result is `is_error` with
"API Error: 403 {"error":{"code":"auth.forbidden","message":"this team cannot use the
model router on this deployment yet",…}}". acpmux's claude bridge turns that into a
failed prompt, the hub records `turn_error` and `turn_result {status: failed, errorText}`
and `lastTurn.errorText`. So the turn ends; it does not hang. What did hang: when the
local relay has no upstream or its sign-in expired, it answered 503, which Claude Code
retries up to 10 times (about 2.5 minutes of "Working", the round 1 observation).

| Mac (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Failed turn note: "The provider refused cmux’s credentials (403)." + Details, Copy error | **Agent stopped**: "cmux's model service isn't available for this team yet." + **Details** (the agent's text), Retry | works (fixed) | Was the raw "API Error: 403 {json}". The phone ports the Mac's `failureCopy` kinds and sentences, plus the model service's own cases (not connected, sign-in expired, didn't answer). Mac-side gap: the Mac's sentence for this case blames credentials; the same case belongs in `failureCopy.ts`. code-checked; live pending |
| Feed | failed item with the same sentence | works (fixed) | Was the chat's previous reply (the preview) or "The turn failed.". |
| (no Mac display) Claude Code's `api_retry` | running turn reads "Retrying (2 of 10, error 503)" | works (new) | From acpmux's raw `claude.system.api_retry` record. |
| Relay with no upstream / expired sign-in | turn ends at once with "cmux's model service isn't connected on the Mac…" | works (fixed, Mac-side `f3ff65e0`) | The relay's own 503s now carry `x-should-retry: false`, and the hosted service's `x-should-retry` is forwarded. Relies on Claude Code honoring the header (the Anthropic SDK's behavior). |

### Live steps for the orchestrator (simulator, real link, rig Mac)

Taps by accessibility label or identifier. Mac checks through the rig's daemon socket
and its acpmux socket (`pq_ws.acp`).

1. **cmux harness 403** (the test account reproduces it): workspace > + > **New Agent
   Chat With…** > Harness **cmux** > **Start Chat**; send "PONG". Expect within seconds:
   the card **Agent stopped** with "cmux's model service isn't available for this team
   yet.", **Details** expanding to "API Error: 403 …", and **Retry**; no "Working" left.
   Mac: `_acpmux/sessions` shows the session with `lastTurn.status` `failed` and
   `errorText` containing `403`. Feed tab: the newest item reads the same sentence.
   If the rig's relay has no upstream, expect "cmux's model service isn't connected on
   the Mac…" at once (not minutes; needs a rig built with `f3ff65e0`).
2. **Permissions**: in a Claude chat, ask "run `echo p3 > p3.txt`". Chat bar shows
   exactly **Allow once** and **Deny** (no "Allow for this session"). Tap **Allow once**,
   Face ID (simulator match); Mac: `p3.txt` exists. Repeat with the chat closed: Feed card
   shows **Allow once** and **Deny** only. Then ask again and answer on the Mac
   (`_acpmux/permission_respond` on the rig socket, `allow_once`), then tap **Allow once**
   on the phone: the card closes "Already answered on your Mac" with no error.
3. **Agent Edits**: ask Claude to create `p3-notes.txt` with three lines, then in the next
   prompt to change line 2, then in a third to change line 3 of it and another file.
   Title menu > **Agent Edits**: `p3-notes.txt` shows the written file with both edits
   applied (A badge, numbered 1-3); a file that existed before shows each edit as its
   own hunk separated by "⋯", no line numbers. **Diff options** > Hide Whitespace on a
   file after tapping an **Expand N hidden lines** row: no crash.
4. **Files and Artifacts**: ask Claude to write `p3.svg` (a circle). Title menu >
   **Files and Artifacts** > the SVG: it draws (was "Not an image"). Open a large text
   file and the PNG: previews load; **Preview**/**Source** toggle (`artifact.sourceToggle`).
5. **Chief**: Home > Chief; send a message; settings (`chief.settings`): change
   `chief.settings.model`, then `chief.settings.stop` while Chief types. Mac:
   `chief.engine.get` shows the model. A Chief question: `chief.question.bar` > answer >
   `chief.question.send` (Face ID); Mac: the question answered.
6. **Team switch**: with a Feed item from team A, hamburger **Teams** > team B row. The
   Feed is empty until team B's Macs fill it; an open workspace screen closed. Switch
   back: team A's last turns return.
7. **Devices**: Settings > `settings.devices` > a second phone row > swipe **Remove**:
   the alert says the Macs still allow it until removed in Settings → Mobile on each Mac.
   Mac: the phone is still in its Phones list (expected; the gap above).

### Round 3: saved tab groups, Duplicate Workspace, opencode (`feat-cnx-ios-p3saved`)

- **Reopen / Delete Saved Tab Group…**: page menu rows open a chooser of the Mac's saved
  groups. Both policies (`policy.rs`, `DaemonLanePolicy.swift`) now take only
  `reopen-saved-tab-group {saved, pane, transaction?}` and `delete-saved-tab-group {saved}`.
  The daemon reopens a terminal member as the login shell in its saved folder (no command,
  no env: the saved record has no command field), or reattaches it while it still runs
  (SECURITY.md "Reopen Saved Tab Group"). **Live check pending (orchestrator).**
- **Duplicate Workspace**: workspace row menu; composed from allowed lines (Workspaces table).
  Needs one live run on a rig: the copy lists the same terminals in the same folders.
- **opencode** stays refused. Checked against opencode v1.19.0 source
  (`packages/opencode/src/config/config.ts` `loadInstanceState`, `src/agent/agent.ts`,
  `src/permission/index.ts`): config sources merge with the later one winning, in this order:
  global config, `OPENCODE_CONFIG`, project files, each config directory (agent files,
  plugins, custom tools), `OPENCODE_CONFIG_CONTENT`, the account's org config, the managed
  directory `/Library/Application Support/opencode`, and the macOS MDM plist ("overrides
  everything"). `OPENCODE_PERMISSION` is merged last, but only into the top-level list. Each
  agent's own `permission` is appended after that, and `Permission.evaluate` takes the
  last matching rule. So a user's agent file, or a later key such as `"b*": "allow"`,
  beats anything acpmux could set through env. Custom tools, plugins, MCP tools (allowed
  by default) and `!` command templates also run outside the edit/bash/webfetch asks.
  `OPENCODE_DISABLE_PROJECT_CONFIG` and `--pure` leave the global, org and managed config
  and custom tools in place. acpmux therefore cannot prove that a phone-started opencode
  asks before each change. Its remote row now gives that reason
  (`web_modes::OPENCODE_REFUSAL`), and the phone shows it.

#### Live check for Reopen Saved Tab Group (orchestrator)

On a rig Mac built from this branch, with the phone paired (the same setup as the Restart
Shell check):

1. Use the rig's daemon socket (`~/Library/Application Support/cmux/cmuxd-dev-<tag>.sock`,
   one JSON line per request). Make two terminal tabs in one workspace pane, and `cd` one of
   them to a project folder (for example `/tmp/p3saved-check`). Then send
   `{"id":1,"cmd":"list-workspaces"}` to get their `surface` numbers and the pane id.
2. Send `{"id":2,"cmd":"create-tab-group","surfaces":[S1,S2],"color":"red"}`, which returns
   the `group`. Then send `{"id":3,"cmd":"save-tab-group","group":"<group>"}`, which returns
   `saved_<hex>`. Run `{"id":4,"cmd":"list-saved-tab-groups"}` to see both members with
   their `cwd`.
3. Send `{"id":5,"cmd":"close-tab-group","group":"<group>","end_terminals":true}`. The
   terminals must end, so that the reopen spawns new shells instead of reattaching. Write
   down the old shell pids from `list-terminals` / `process-info` first.
4. On the phone, open any terminal tab of that workspace. Tap the page menu >
   **Reopen Saved Tab Group…** > the red group ("2 terminals").
5. Read back on the Mac. `list-workspaces` should list two new tabs in that pane, grouped,
   with the group's `saved_id` set. For each new terminal, use `process-info` or `ps -o
   pid,ppid,command`: the shell is new (not the old pid), its parent is the rig app's own
   `cmux-tui __terminal-host --owner <rig bundle id>`, and its cwd (`lsof -p <pid> -a -d
   cwd`) is the saved folder. Type `pwd` from the phone into the reopened tab.
6. Tap Reopen again on the same group: the phone says "The saved group is already open."
   and the Mac gets nothing.
7. Send refused lines through the phone's lane, as `restart-tab` was checked: hostd must
   answer `forbidden` to `reopen-saved-tab-group` with `command`, `argv`, `cwd` or `env`
   added. Then tap **Delete Saved Tab Group…** > the group. `list-saved-tab-groups` no
   longer has it, and the open group stays.



## Round 3 live run (2026-10-15, branch `feat-cnx-ios-parity3`)

- **Mac:** real cmux-next builds of this branch, fleet jobs `ffbb033cc9c0925ead8a467c`
  (`cmux-mobile-p3-aa685b82`, the round-2 head) and `10e58b9c35dfc0f123e44f15` (`cmux-mobile-p3-153f3482`,
  all three round-3 lanes merged plus the acpmux fixes below), on mini-cmux11s, settings by
  `open --env` and its own `cmux-next.json` only. Codex: the same build as a hidden laptop rig
  (`open -g -j`, the laptop's Codex login in place), quit after; no prompt appeared.
- **Phone:** this branch's Debug app (`ARCHS=arm64`) in one simulator (`cmux-mobile-p3`), real link.
  Driver `verify/parity/p3.py`. Mac-side picks go through the rig app's own New Tab page with
  cua-driver accessibility actions on the mini (background, no focus).
- **Videos:** `~/cmux-next-ios-e2e/p3-raw/*.mp4` on the laptop (not committed).

| Flow | Result | Video |
| --- | --- | --- |
| `last_pick`: the Mac's New Tab page picks Haiku 5.5 (then, on the next build, Sonnet 5.5); the phone's New Agent Chat in a folder the Mac never picked in | Pass both times: acpmux `lastPicks.global` followed the Mac's pick; the phone's chat ran on it (`claude-haiku-5-5`, then `claude-sonnet-5-5`), "PONG" in 3.6 s / 1.9 s | `last-pick.mp4` |
| `queue`: an approved 90 s command, then two prompts; Move up, Edit queued prompt, Send now | Pass after two fixes (below): queued on the Mac, Move up 0.3 s, Edit 0.3 s, Send now 0.5 s, each read back from the Mac's queue; the agent answered BRAVO and CHARLIE | `queue.mp4` |
| `codex_agent_mode`: a Mac-started Codex chat (Agent mode) in a workspace tab, prompted from the phone | Pass: hostd's refusal on the phone; the Mac session's turn count unchanged | `codex-agent-mode-chat.mp4` |
| `saved_group`: Reopen / Delete Saved Tab Group… | Pass (SECURITY.md "Reopen Saved Tab Group": new login shells under the rig app's host, saved folders) | `reopen-saved-group.mp4` |
| `groups`: Move Workspace to New Group "Ship", Rename Group… "Release", Set Workspace Group Color… Cyan, collapse / expand, Move Workspace to Group…, Remove Workspace from Group, Delete Group | Pass: each read back from the Mac's `list-personal`; the workspace stayed open after Delete Group | `groups.mp4` |
| `duplicate`: Duplicate Workspace of a two-terminal workspace (one in `/tmp/p3dup`) | Pass: a second workspace of the same name in 0.2 s, two new shells of the Mac's own host in `~/…/p3/proj` and `/private/tmp/p3dup` | `duplicate-workspace.mp4` |
| Agent Edits: a file written, then edited in two later turns | Pass: one added file `p3-notes.txt`, `+3`, lines one / TWO / THREE, the same file the Mac has | `edits-artifacts.mp4` |
| Files and Artifacts: an SVG the agent wrote | Pass once the folder is shared (the rig had no Chat Folders: "isn't sharing any folders", now with where to share it); the SVG draws (it renders at its own size, top left, not fitted) | `artifacts-svg.mp4` |
| Permission bar in the chat and the Feed | Pass: only **Allow once**, **Deny**, **Reply instead**; Allow needs Face ID. A permission answered on the Mac closes the phone's bar in 0.4 s; the Feed card reads "Answered" | `answered-on-mac-chat.mp4`, `feed-permission.mp4` |
| Feed › Reply on a chat the Mac started outside any tab | Fixed: it read "You replied" while nothing was sent; now "This chat isn't in a workspace tab on the Mac, so it can't be answered from here. Open it in cmux on the Mac." | `feed-reply-no-tab.mp4` |
| Chief: open, a message, Chief Settings | Pass: loaded 1.0 s, the Mac Chief's reply 5.5 s; settings show Harness Claude and the model (Mac `chief engine`: claude · default · medium) | `chief.mp4`, `chief-settings.mp4` |
| `cmux` agent (Claude Code (cmux)) | The rig's local model router hangs in a Keychain read (`SecKeychainFindGenericPassword`, a prompt nobody sees on a rig), so acpmux answers `route.unavailable`; the phone said only "Couldn't open an agent chat". Fixed: "cmux's model service isn't running on the Mac. Quit and reopen cmux on the Mac, then try again, or choose another agent." The 403 copy ("cmux's model service isn't available for this team yet.") is unit-tested only: no rig reached the hosted router | — |
| Team switching | Not driven: the test account has one team (Personal) and the phone has no Create Team. Unit-tested (Feed empties and refills on a switch) | `teams.mp4` |
| Settings › Devices removal alert | Not driven (needs a second phone on the account); unit-tested wording | — |

### Findings fixed in round 3

1. **Every Bash command of a phone-started Claude chat failed** with "operation not
   permitted: /tmp/claude-<id>-cwd": Claude Code keeps its temporary files under
   `CLAUDE_CODE_TMPDIR`, else the shared `/tmp`, which the remote-chain profile never lets it
   write. acpmux now sets it to the spawn's own folder (Mac-side, red/green test
   `claude_codes_temporary_folder_is_the_spawns_own`). Live: the same script now returns
   `WAITED`, `is_error: false`.
2. **Move up and Edit queued prompt never showed on the phone**: acpmux left `queue_updated`
   and `queue_order` out of its `transcript` records. Both sides fixed: acpmux includes them
   (Mac-side, red/green `queue_edits_are_transcript_records`), and the phone asks for them by
   name, so an older Mac works too (`ChatKindsTests`).
3. **A down model service read as a generic failure** (`route.unavailable`), fixed above.
4. **Files the Mac doesn't share** now say where to share them: "To open it here, add its
   project folder in cmux on the Mac: Settings › General › Chats › Chat Folders."
5. **Feed replies that were never sent read as sent**, fixed above; a reply the Mac refuses
   now shows the chat's own reason under it.
6. Round 2's "not queued" was a driver bug: the second prompt was typed before the first Send
   landed, so both went as one prompt (the Mac's chat list shows it). The round-3 driver waits
   for the composer.

### Remaining gaps after round 3 (and why)

- **opencode** from a phone: still refused, with its own reason ("opencode's own settings on
  this Mac can let it edit and run commands without asking"). opencode's later config sources
  (org, managed folder, MDM, per-agent rules evaluated last-match) can always override a
  permission config acpmux sets, so no mode provably asks (round 3 notes above).
- **`cmux` agent's 403**: the phone's sentence is unit-tested; seeing it live needs a rig whose
  local router can read its Keychain item (a person's Mac) and reaches the hosted router.
  The rig router's Keychain wait is a rig artifact, but it blocks the router's whole admin
  socket, so on a person's Mac a pending Keychain prompt stalls every `cmux` chat start
  (owner: cmux-coderouter, `KeychainInstallSecretStore::load`).
- **Replying to a chat the Mac started outside any workspace tab**: not from a phone (the
  phone sends prompts through a workspace's chat tab); the Feed now says so.
- **Folder trust from the phone**, **Open Link in New Tab, Checkpoints, Commit, Push, New
  Chief…, Memory Inspector, Reset Terminal, Keep Running After Close**: unchanged from round 2.
- **Team switching and device removal**: unit-tested only (one team, one phone on the test account).
- **File previews by default**: the Mac shares only its Chat Folders with phones; with none set,
  no session file opens on the phone. Sharing the workspace folders by default is the pending
  file-roots decision (#13742).
- Polish: an SVG preview drew at its own size in the corner (now centered and fitted, `FittedSVGTests`; not re-driven live); a chat opened from a Feed tap once
  showed a permission the Mac had already answered (not reproduced; opening it again was current).

### Review (correctness-first subagent, round 3)

No blocker: the relay allowlist holds (exact param sets on both lists, `command`/`argv`/`cwd`/
`env`/host refused, ownership read on the bytes hostd forwards, the daemon's reopen only
reattaches or starts the login shell). Fixed after it (ee607662): API retries reach the chat
(`claude.system.api_retry` asked for by name); Move Workspace to New Group deletes the group
it made when the place fails; Duplicate Workspace closes a half-made copy and no longer lets
a failed page stop the terminals; unique group section ids; a lone single-use Deny keeps the
lasting Allow beside it. Re-driven live on the reviewed app: `groups` and `duplicate` pass.
Accepted and documented (SECURITY.md): an empty group's ownership, check-then-forward, the
Swift lane's create-without-place. Left as nits: format characters in group names, remote
images in SVG/HTML previews (scripts are off; no network block), a Feed reply showing a
later chat error, a Feed refill racing a team switch, a group rollback racing a second change,
a file read's timeout racing its last chunk, a written-then-failed-edit file labeled Added.

## Diff viewer (menu-rows batch)

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Diff: Next Hunk / Previous Hunk (⌃N / ⌃P) | file diff bottom bar: double chevrons | works (menu-rows batch; live) | Each run of changed lines; a folded hunk unfolds. Next / Previous file keep the single chevrons. |
| Diff: Search (/) | file diff toolbar **Search in File**: a find bar, "N of M", previous / next | works (menu-rows batch; live) | Ignores case and diacritics; matches are highlighted, the current one has a bar at the leading edge; folded context with a match unfolds. |

## Hidden local Chief agent approvals

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Home Allow / Deny for a hidden local owner subagent | Person-proven local `_acpmux/permission_respond`, exact pending request, `allow_once` / `reject_once` | No new phone authority | not from a phone | This surface requires the Mac app's local person proof and a fresh native click. SECURITY.md's “phone acts for the person, but is not the app” rule excludes this proof; existing phone questions retain their separate asking-mode policy. Other-person `ask` children and cloud peers remain excluded. |

## Chat polish (chat-polish batch, `feat-cmux-next-ios-chat-polish-parity`)

Rows from the 2026-11-02 re-audit that need no Mac or host change. Each was checked against
acpmux `server/remote_guard.rs` and the phone lanes first: every call below is a per-chat
acpmux request the guard has no rule against, on a chat the phone may see.

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Copy Agent Name / Harness Session ID / Session Details / Working Directory / Chat Host | `_acpmux/info` (AgentChatCopyHandlers) | page menu **Copy…**: one row each, plus Copy Session ID and Copy Conversation as Markdown | works | Session Details leaves out the session file paths: acpmux names them only over the Mac's own socket (`_acpmux/session_files` is local only). Conversation as Markdown follows webviews `header/copyRow.ts` (prompts, answers, tool titles only). |
| Toggle Session Info | the pane's Session Info | page menu **Session Info** (pushed): environment, model and context, Agent Edits, Files and Artifacts, Subagents, Permissions, Replay, Event Inspector | works | Each value copies on a tap. |
| Previous / Next Turn, Previous / Next Bookmarked Prompt | page scroll (thread minimap) | page menu **Jump to Turn…**: a bar under the header with up and down, and Bookmarked prompts only | works | No wrap at the ends, as on the Mac. |
| Bookmark this turn (minimap), Pin (message row) | `_acpmux/bookmark_set {sessionId, seq, bookmarked}` (`user_message` / `turn_result` seq) | prompt menu **Bookmark** / **Remove Bookmark**; answer More **Pin** / **Unpin** | works | Marks made on the Mac show on the phone (the `bookmarks` record is read with the chat). |
| Agent Chat: Zoom In / Zoom Out / Actual Size, Text & Width | `agentPane.zoom`, `agentPane.display.*` (global cmux.json) | page menu **Text and Width…**: text size steps and Full Width / Standard | works | Saved per chat on the phone (the newest 300 chats), as the re-audit asked; the Mac's keys are global and stay the Mac's. |
| Read aloud (message row) | the app's `AVSpeechSynthesizer` | prompt menu and answer More: **Read Aloud** / **Stop Reading** | works | Same spoken text rules (code blocks dropped, markup removed); one message at a time; stops when the chat leaves the screen. |
| Revoke Chat Permission, Refresh Permissions, Check and Retry Permission | `_acpmux/permission_chat_revoke`, `_acpmux/permission_groups`, a re-sent answer | Session Info > Permissions | works | Allow for This Chat itself stays the Mac's (a lasting grant needs the person, #13742). Check and Retry re-sends the phone's own last answer when it did not reach the Mac and the ask is still open. |
| Toggle Event Inspector | the page's wire and session journal | Session Info > **Event Inspector**: the records this phone received for the chat (newest 500), filter, JSON, Copy as JSON Lines, Clear | works | The phone has no separate wire view: its records are the session journal. |
| Replay Conversation | `_acpmux/events {kinds: [transcript]}` | Session Info > **Replay Conversation** | works | Play/pause, 0.5-16×, scrubber with tool-call ticks, Previous/Next tool call; pauses over 2 s are cut to 2 s. Continue from here is not on the phone. On the Mac the row is behind the `session-replay` experiment. |
| Launch Claude Teams / Launch Codex Teams | `new-tab` + `send` of the team line | grid + menu **Launch Claude Teams** / **Launch Codex Teams** | works | The tab opens in the shown tab's pane and changes to its folder first. |
| Message the Chief (from any app) | the Chief pet's reply box | App Intent **Message Chief** (Shortcuts, Siri, Spotlight, Action Button) with optional text | works | Opens the message box with the text; nothing is sent until Send. |
| Attach photos to Cloud Chief | Cloud `/v1/home/attachments` intent, PUT, commit | Cloud Chief composer's photos | works | The Cloud service accepts them (home-messaging.md 10.1). |
| Home: Reply to Selection, Chief: Zoom In / Out / Actual Size | Home transcript | none | missing (needs a CmuxConversation change) | The Chief conversation is CmuxConversation's `ConversationViewController`: its fonts are app-wide (`ConversationTheme`) and its bubble selection menu is internal, and this package must stay byte-identical to its upstream branch. |

## Mac features after 2026-10-26 (new-mac-rows batch)

Rows from the re-audit of the Mac's catalog after 2026-10-26 that need no host change. Cloud rows
call the service with the phone's own account (`CmuxMobileChief/AccountCloud.swift`), never a Mac
or the relay. States here are from the live run in this batch's proof report. Rig flows: `verify/parity/pq_newrows.py`.

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Automations page (list, Run now, Pause / Resume, Delete) | `cloud.automation`: `automation.list`, `automation.runs.list` (`/v1/read`), `automation.run` / `update {enabled}` / `delete` (`/v1/ops`) | Settings → Cloud → **Automations**: Needs you / Today / Later / Paused; a row pushes its page (Run Now, Pause or Resume, Delete, History); swipe to pause or delete | works (live) | Cloud automations only: this Mac's local runner (`cmux automation list`) is the Mac's own store, not on the phone's lane. Delete asks first; its run history stays. |
| Show Artifacts (synced tree, preview, history) | platform `/v1/artifacts/tree`, `/file`, `/history` with the app's bearer | — | not from a phone (blocked) | The platform's artifact reads take only "a cmux access token of a team install" (`artifacts.unauthorized`, checked live on the development platform 2026-11-03); that token is minted from a Mac's install key (`cmux auth token`). The phone's own account token is refused, so a phone page needs the platform to accept a signed-in person's token for reads, or a phone install grant: a trust decision (#13742). |
| Delete Conversation from List / Show Hidden Conversations | the Mac's Home source (local) | Home row menu **Delete Conversation from List** (asks first); **Show N Hidden Conversations** under the list | works (live) | Kept per account on this iPhone, like the Mac's; a newer message brings the row back. |
| Next-step card (a tagged ask at a turn's end) | the agent pane's `nextStepAsk.ts`; an answer is a `session/prompt` | the same card under the answer: question, muted line, answer buttons; a tap sends the answer; the card folds to the answer once a prompt follows | works (live) | `NextStepAsk.swift` is a port of the Mac's reading, as strict (one tagged question, 2-4 answers or a yes-or-no question). |
| Continue or Retry leads a failed turn's error card | `_acpmux/retry` | **Continue** when the turn had done work (or had no prompt of its own), else **Retry** | works (live) | Both are acpmux's turn retry, as on the Mac. |
| New Agent Chat on… | palette picks the machine, then `session/new` there | Workspaces → New Workspace (hold) → **New Agent Chat on…** → a Mac → one of its folders | works (live) | This Mac's acpmux only. A peer machine or a Cloud machine as the destination is not from a phone: `_acpmux/route/*` is unix-socket only (acpmux `remote_guard.rs`), a trust decision for #13742. |
| Toggle Prompt Queueing | the page's `queueing.ts` (app-wide), `_meta.acpmux.steer` | a chat's page menu **Turn Off / Turn On Prompt Queueing** (the same choice as Settings → Composer) | works (live) | App-wide on this iPhone, as the Mac's is app-wide. |
| Copy Session File Paths / Transcript File / Harness Config / Harness Settings / acpmux Session File | `_acpmux/session_files` | — | not from a phone | acpmux answers it only over its local unix socket (`server/session_files.rs`, `session_files.local_only`); a Web origin would need a guard change (#13742). |
| Move Workspace Above… / Below… | `set-personal-workspace {index}` / `move-workspace` | a row's menu → Move → **Move Workspace Above…** / **Below…** → a row of the same container | works (live) | |
| Reveal Workspace in Sidebar | the sidebar scrolls to the row and flashes it | a workspace page's menu **Reveal in Workspaces List** | works (live) | A row behind the Mac filter or in an offline Mac's fold shows first. |
| Compact Workspace List | the sidebar's one-line rows | Settings → **Compact workspace list** | works (live) | |
| Toggle Editor Minimap | the Mac's code editor | — | not applicable | The phone's file preview is a read-only view with no minimap. |
| Help: Troubleshooting and Support, Join the cmux Discord, Follow @cmux on X, cmux on GitHub | open the page | Settings → About rows | works | The Mac's `StaticURL` addresses. |
| Copy Logs | the error journal report | Settings → About → **Copy Logs**: this app's own log (last hour, this launch) with its version | works (live) | Private values stay redacted (OSLog). |
| Chat Colors… | the Mac's Home transcript colors (local) | — | missing (blocked) | The phone's chats draw in CmuxConversation, which has no bubble color hook and must stay byte-identical to its upstream; needs a CmuxConversation change upstream first. |
| Make Primary Chief | `chief.update {is_default: true, expected_rev}` | the Cloud Chief row's menu **Make Primary Chief** | works | The account's own write; one revision conflict reads the list again. |
| Connect GitHub | `integration.list`, `integration.connect {provider: github}`, the App's installation page | Settings → Cloud → **Connect GitHub** (state from `integration.list`; a tap opens the installation page) | works (live: the state; the install leg in tests) | Only `https://github.com/apps/<app>/installations/new` may open (the Mac's check). The development service has no GitHub App configured, so the live row reads "Not available" there, as the Mac's would. |
| Fork Conversation to New Column Right | `new-conversation-tab`, `move-tab-to-column` | Fork Conversation → **In a New Column** | works (live) | |
| Customize Right-Click Menus… | the Mac's menu editor | Settings → **Long-Press Menus**: each item of the workspace row and Home row menus on or off | partial | Hiding only; the Mac also reorders. Close Workspace always stays. |
| DEV build signs in as the NIGHTLY account (`CMUX_NEXT_DEV_ACCOUNT=nightly`) | control socket `auth.session.handoff` from a signed DEV build to the running cmux NIGHTLY, same user and cmux team signature both ways | — | not from a phone | Mac-only: two apps on one Mac hand a session over their local socket, checked by uid and code signature. A paired phone signs in on its own and may not read the Mac's session (SECURITY.md). |
| Gallery Stage (`gallery.openStage`, NIGHTLY and DEV) | none: a gallery stage from the Mac's loopback gallery dev server in a tab of the Mac's window | — | not from a phone | Mac-only chrome and a developer tool: the stage comes from a dev server on the Mac's loopback and shows in the Mac's own window backdrop, which a phone cannot reach or draw. |
| Update in One Click (`updates.oneClickInstall`, off by default) | none: the Mac's own updater; Update on a found update downloads, installs and relaunches the Mac app | — | not from a phone | Mac-only chrome: it changes how the Mac app installs its own update (Sparkle) and relaunches. The phone updates through the App Store; the key stays settable over `cmux settings` on the Mac. |

## Terminal tools batch (`feat-cmux-next-ios-terminal-tools-parity`)

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Toggle Copy Mode (⇧⌘M) | terminal page menu **Select Text…**; ⇧⌘M from a hardware keyboard | works | A cursor over the phone's copy of the rows, scrollback included. vi keys: h j k l (and arrows), w b, 0 $, g G, v selects, y copies (the cursor's row with no selection), Escape leaves. Select Text… starts with the cursor's row selected; the selection handles still move either end, and the bar above the composer has Copy and Done. A full-screen app keeps its long-press selection (no Copy Mode, as its screen is its own). |
| Select All | terminal page menu **Select All** | works | Every row, scrollback included; Copy in the edit menu. |
| Scroll to Top | terminal page menu **Scroll to Top** | works | The first row the phone holds. |
| Send Text… | terminal page menu **Send Text…** | works | Typed into the Mac's terminal as is, no Return (`send`). |
| New Tab to the Right / of the Same Kind / at Start / at End | tab page menu | works | A tab of the tab's kind in its pane (`new-tab`, `new-browser-tab {about:blank}`, or a new chat of the same agent with `new-conversation-tab`), then `move-tab {index}`: after the tab's whole tab group and never among pinned tabs, as the Mac's `NewTabSlot` (Same Kind goes there too, the Mac's default `tabs.newTabPosition`). Not on phone tabs (the Mac opens those). |
| Clear Tab Name | tab page menu and card menu, on a named tab | works | `rename-surface {name: ""}`. |
| Copy Tab Link / Tab ID / Pane Link / Pane ID / IDs | tab page menu | works | The Mac's text (`surface_id=tab_…`, `pane_id=…`, `workspace_id=…` lines; `cmux://tab/…`, an agent tab's `cmux://session/…`), only when the Mac sent the ids. |
| Copy Workspace Link / ID / ID and Ref | workspace row menu > Copy | works | Same text as the Mac. Copy Workspace Path stays the terminal's Copy Directory (the phone has only the abbreviated folder). |
| Duplicate Workspace | workspace row menu | works | Now the Mac's blueprint: screens, scrolling columns (with widths), splits (with ratios), each terminal in its folder (`cd` typed), each web page, color and icon (a color with alpha loses its alpha: the phone reads `#RRGGBB`). Agent chats and docks are not copied, as on the Mac. |
| Duplicate Workspace Without Browser Tabs | workspace row menu (a workspace with a page) | works | A pane of pages only goes and its split collapses, as the Mac's `withoutBrowserTabs`. |
| Send Feedback | Settings > About > **Send feedback** | works | Opens the Mac's feedback page (a new issue). Replaces "Report a problem". |
| Phone tab: rotate, appearance, software keyboard, volume, app switcher | — | blocked (#13742) | The simulator stream takes `button` home and lock only (`cmux-mobile-host/src/surface.rs` `BUTTONS`; the Mac's `SimulatorSurfaceServer` maps only those). Each needs a new stream input in the mobile host and the Mac's surface server. The phone's own keyboard toggle (typing into the simulator) is already in the accessory bar. |
