import Foundation
import CmuxNextCompat
import os

/// Where the daemon listens, as printed by `server ensure`.
public struct DaemonEndpoint: Hashable, Sendable {
    public var socketPath: String
    public var pid: Int32?
    public var generation: DaemonGeneration?
    /// Connect through this child process instead of `socketPath`
    /// (``DaemonBridge``: a paired server's owner session through `cmux link
    /// dial`). `socketPath` then only names what to watch for changes.
    public var bridge: DaemonBridge?

    public init(socketPath: String, pid: Int32? = nil, generation: DaemonGeneration? = nil, bridge: DaemonBridge? = nil) {
        self.socketPath = socketPath
        self.pid = pid
        self.generation = generation
        self.bridge = bridge
    }
}

/// A daemon capability the GUI relies on (plans/cmux-next/cmux-tui-contract.md 2.2): one case per
/// wire name, which is its `rawValue`.
///
/// Every case is in exactly one ``Tier``. ``tier`` is an exhaustive `switch` without a `default`,
/// so a new case does not compile until it is placed in a tier, and ``required``, ``optional`` and
/// ``unservedByBundledDaemon`` are derived from `allCases`: no list is kept by hand.
/// DaemonCapabilityExportTests writes them to plans/cmux-next/daemon-capabilities.json, and
/// scripts/cmux-next/check-daemon-capabilities-fresh.py reads this declaration without a build.
///
/// ```swift
/// guard daemon.supports(DaemonCapability.tabDrag.rawValue) else { return }
/// ```
public enum DaemonCapability: String, CaseIterable, Sendable {
    /// The GUI refuses a daemon without these (`DaemonCompatibility.missingRequired`).
    case workspaceRegistry = "workspace-registry-v1"
    case viewportSplits = "viewport-splits-v1"
    case viewportColumnResize = "viewport-column-resize-v1"
    case layoutUndo = "layout-undo-v1"
    case viewAttachmentLease = "view-attachment-lease-v1"
    case viewAttachmentDetach = "view-attachment-detach-v1"
    case attachInitialSize = "attach-initial-size"

    /// Additive protocol 12 capabilities from cmux-tui PR 15518
    /// (cmux-tui/spec/commands.md). The GUI hides the matching features when
    /// a daemon lacks them (`DaemonIdentity.supports`).
    case workspaceGroups = "workspace-groups-v1"
    case workspaceMetadata = "workspace-metadata-v1"
    case workspaceNameSource = "workspace-name-source-v1"
    case tabMetadata = "tab-metadata-v1"
    case frontendBrowserTabs = "frontend-browser-tabs-v1"
    case frontendBrowserTabKeys = "frontend-browser-tab-keys-v1" // idempotency_key on new-frontend-browser-tab
    /// A frontend browser tab's back/forward entries and scroll positions,
    /// stored opaque and outside the journal (`set-`/`get-frontend-browser-history`).
    case frontendBrowserHistory = "frontend-browser-history-v1"
    /// `profile_id` on `update-frontend-browser-tab`: the tab moves to another browser profile in place.
    case frontendBrowserTabProfile = "frontend-browser-tab-profile-v1"
    case tabDrag = "tab-drag-v1"
    /// `set-size-counts` (protocol 12): a hidden view keeps its lease and stops counting toward
    /// the grid (`TerminalAttachment.sendHidden`). The GUI reads it from `identify`; it does not
    /// advertise it back (that would subscribe its streams to `size-state` events).
    case sharedSizing = "shared-sizing-v1"
    /// `name` on `move-tab-to-new-workspace`: the new workspace takes the
    /// moved tab's name in the same commit (else the app renames after).
    case tabWorkspaceName = "tab-workspace-name-v1"
    case notificationAck = "notification-ack-v1"
    /// The daemon's local feed owner (plans/cmux-next/feed.md 9.1): every
    /// notification is also a local feed item, selection never clears unread,
    /// `ack-tab-notifications` reports `refused` items, and the
    /// `feed-local-*` commands let the app hand items to the cloud owner.
    case feedLocalOwner = "feed-local-owner-v1"
    case tabGroups = "tab-groups-v1"
    case savedTabGroups = "saved-tab-groups-v1"
    /// The sidebar workspace pin: `pinned` on `set-workspace-metadata` and workspaces.
    case workspacePin = "workspace-pin-v1"
    /// Each workspace's checklist (`workspace_checklist.*` and the `workspace_checklist` state resource).
    case workspaceChecklist = "workspace-checklist-v1"
    /// The manual workspace unread mark: `marked_unread` on
    /// `set-workspace-metadata` and workspaces.
    case notificationMarkUnread = "notification-mark-unread-v1"
    /// The manual tab unread mark (Mark Tab Unread): `marked_unread` on
    /// `tab.update` and the tab's `extra.marked_unread`; no notification needed.
    case tabMarkUnread = "tab-mark-unread-v1"
    /// Agent attention mark on a tab.
    case tabAttention = "tab-attention-v1"
    /// Owner-issued request identity and compare-and-clear for attention marks.
    case tabAttentionRequestID = "tab-attention-request-id-v1"
    /// A workspace's description: `description` on `workspace.update` and the
    /// workspace's `extra.description` (Edit / Clear Workspace Description).
    case workspaceDescription = "workspace-description-v1"
    /// A workspace's manual task status (classic lanes): `task_status` on
    /// `workspace.update` and the workspace's `extra.task_status`.
    case workspaceStatus = "workspace-status-v1"
    /// Screen color, icon, pin, and order (`set-screen-metadata`,
    /// `set-screen-pinned`, `move-screen`; `screen.update` and `screen.move`
    /// with `stateResources`, over the same storage).
    case screenMetadata = "screen-metadata-v1"
    /// Screen groups and saved screen groups (`screen_group.*` with
    /// `stateResources`).
    case screenGroups = "screen-groups-v1"
    /// The state resources over `cmux.protocol/2` (state-ownership.md steps
    /// A and B): closed history, ephemeral workspaces, workspace status,
    /// screen metadata and groups, tab records, terminal progress, and the
    /// v2 state mutations, mirrored through `session.events`. The daemon
    /// advertises it in `identify` (`DaemonStore.servesStateResources`).
    case stateResources = "state-resources-v1"
    /// `window_record.put` / `.delete` / `.list`: one record per app window, keyed by install and
    /// window id. The app mirrors its windows there so closed history knows each group's window,
    /// and a window it closes becomes a closed-history `window` group (reopen-closed.md 4).
    case windowRecords = "window-records-v1"
    /// Per-terminal `env` on `new-tab`, `split`, `create-terminal`; `cwd` on `split`.
    case terminalEnv = "terminal-env-v1"
    /// Caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and
    /// `new-pane-right`; `cwd`/`env` on the last two (cmux-tui PR 15600).
    case terminalPlacementEnv = "terminal-placement-env-v1"
    /// Client-minted `pane_id` / `tab_id` on `split`, `new-pane` and `new-pane-right`, keyed
    /// retries (plans/cmux-next/remote-state-ownership.md S1).
    case splitClientKeys = "split-client-keys-v1"
    /// `split` takes a client-minted `split_id` and layout split nodes carry `split_id`.
    case splitClientSplitID = "split-client-split-id-v1"
    /// Client-minted `pane_id` / `tab_id` on `new-row` (New Row in the key's turn), as
    /// ``splitClientKeys`` on `split`.
    case rowClientKeys = "row-client-keys-v1"
    /// Keyed `new-row` retries return the original row without creating it again.
    case rowClientReplay = "row-client-replay-v1"
    /// `new-conversation-tab {pane, split}`: a chat or New Tab page tab in a new split, in one
    /// daemon commit and one `pane-added` delta (a person's Cmd-D, atomically).
    case conversationTabSplit = "conversation-tab-split-v1"
    /// `send {terminal_id}` to a terminal still being created: the daemon queues the input and
    /// writes it after the commit (cx-wb5.78, ``SendTerminalInputRequest``).
    case terminalInputWhileCreating = "terminal-input-while-creating-v1"
    /// The owner ends a terminal with no tab after a grace period unless it
    /// is kept: `keep` on creation, `set-terminal-keep`, and
    /// `shutdown-daemon end_terminals` (cmux-tui PR 15600).
    case terminalReap = "terminal-reap-v1"
    /// `terminal-resume-command`: a person's resume command for one terminal,
    /// typed on the new prompt when the daemon respawns it.
    case resumeCommand = "resume-command"
    /// The owner's reaper runs now (started with a reap grace, as the app
    /// starts it), so a detached terminal ends after the grace period. An
    /// owner started without a grace does not serve it.
    case terminalReaperActive = "terminal-reaper-active-v1"
    /// `keep_layout` on `shutdown-daemon end_terminals`: every terminal ends
    /// but placed ones keep their tabs, dead, so the next launch restarts a
    /// shell in each with the same splits (Quit's End Sessions, Keep Layout).
    case endTerminalsKeepLayout = "end-terminals-keep-layout-v1"
    /// `close-tabs` and `end_terminals` on the container closes: many tabs and
    /// the terminals they end close in one daemon commit.
    case batchClose = "batch-close-v1"
    /// `expect_foreground` on `send`: the daemon writes only while that program is still the
    /// terminal's foreground (the Chief pet's typed reply).
    case sendExpectForeground = "send-expect-foreground-v1"
    /// `reason` on `close-tabs` (`session_end`: not recorded in closed history).
    case closeReason = "close-reason-v1"
    /// `if_empty` on `close-workspace`: the daemon closes the workspace only
    /// when it has no tab at commit time (`workspace_not_empty` otherwise).
    case closeWorkspaceIfEmpty = "close-workspace-if-empty-v1"
    /// `browser-host-provider`: the verified app's credentials for the daemon's browser host.
    case browserHostProvider = "browser-host-provider-v1"
    /// `activate` on `new-frontend-browser-tab`: a background tab keeps the pane's active tab.
    case frontendBrowserActivate = "frontend-browser-activate-v1"
    /// `after` on `new-frontend-browser-tab`: a link's tab lands next to its opener.
    case frontendBrowserInsertAfter = "frontend-browser-insert-after-v1"
    /// Browser tabs reach the machine's loopback services over a dedicated
    /// connection (`LoopbackForwardClient`, plans/cmux-next/remote-localhost.md).
    case loopbackForward = "loopback-forward-v1"
    /// The daemon starts the remote browser host on its machine
    /// (`browser-runtime-*`, cx-2cob slice 2); the app reaches it through
    /// `loopbackForward` on the same connection (`LoopbackForwardClient`).
    case browserRuntime = "browser-runtime-v1"
    /// `source` on notifications (cli, terminal, agent, daemon), and OSC 9,
    /// OSC 777 and OSC 99 parsed by the daemon from every terminal's output
    /// (plans/cmux-next/notifications.md).
    case notificationSource = "notification-source-v1"
    /// `shell_args` on the terminal-creating commands, so bash and nushell
    /// get Ghostty's argv-based shell integration (`GhosttyShellIntegration`).
    case terminalShellArgs = "terminal-shell-args-v1"
    /// Echoed only by a connection whose terminals get Ghostty's shell
    /// integration from this app (`DaemonConnectionConfiguration
    /// .resolvesShellIntegration`): the daemon then starts the terminal's
    /// `SHELL` as given and adds no integration of its own (R92 bug 2).
    case terminalFrontendShellIntegration = "terminal-frontend-shell-integration-v1"
    /// `launch_snapshot_path` in `identify`: the daemon's last settled tree
    /// and window records, read before connecting (`LaunchSnapshot`).
    case launchSnapshot = "launch-snapshot-v1"
    /// Profiles (plans/cmux-next/data-model.md): the `*-profile` commands,
    /// `move-workspace-to-profile`, `profiles` in `list-workspaces`, and a
    /// `profile` field on workspaces, groups and saved tab groups.
    case profiles = "profiles-v1"
    /// `remote_localhost` on personal workspaces (`set-personal-workspace`,
    /// `list-personal`): the person's per-workspace remote-localhost choice.
    case personalRemoteLocalhost = "personal-remote-localhost-v1"
    /// `identify.session_id` and `identify.machine_name` (data-model.md 1.1);
    /// informational, the app falls back to `registry_id` and its own names.
    case sessionIdentity = "session-identity-v1"
    /// Remote-terminal tabs in a home layout: `new-remote-terminal-tab`,
    /// `update-remote-terminal-tab`, `remote-terminal-snapshot`, tab kind
    /// `remote-terminal` with `remote` (data-model.md 1.2b, 1.4, 1.5), and
    /// `terminal_resource_id` in the `set-terminal-keep` result.
    case remoteTerminalTabs = "remote-terminal-tabs-v1"
    /// Docked columns: `set-column-dock` and `columns[].dock`
    /// (plans/cmux-next/dock-column.md).
    case dockColumns = "dock-columns-v1"
    /// Top and bottom docks: `set-column-dock` and `move-tab-to-column`
    /// accept edges `top` and `bottom`, sent back as `columns[].dock`
    /// (plans/cmux-next/layout-model.md).
    case edgeDocks = "edge-docks-v1"
    /// `dock.role` (`agent_chat`) on `set-column-dock`, `move-tab-to-column`
    /// and `columns[].dock`: the agent chat column.
    case dockColumnRole = "dock-column-role-v1"
    /// Split Down of a pane in the agent chat dock adds a pane below it there (#29848);
    /// every other new pane in the dock is still refused.
    case dockColumnSplitDown = "dock-column-split-down-v1"
    /// Pinned dock columns (the Home dock): `set-column-dock` takes `pinned`,
    /// and the daemon keeps a pinned column's first tab and refuses other
    /// tabs into it unless its `allow_tabs` is on (`dock-column-pinned`).
    case pinnedDock = "pinned-dock-v1"
    /// A pinned column may be a screen's only column (Home's dock with nothing beside it):
    /// `move-tab-to-column` with a pinned dock moves a screen's only tab without `respawn`, and
    /// closing the last column beside it leaves the dock alone instead of being refused.
    case pinnedDockAlone = "pinned-dock-alone-v1"
    /// Rows: `new-row`, `set-row-heights` and `columns[].rows`
    /// (plans/cmux-next/rows.md). Without it no row op is sent.
    case rows = "rows-v1"
    /// `move-column`: a whole viewport column (every pane in it) moves one
    /// place left or right in one commit. Without it only a one-pane column
    /// moves, through `swap-pane`.
    case columnMove = "column-move-v1"
    case columnLeft = "column-left-v1"
    /// `move-tab-to-column` `respawn`: a pane's only tab moves into a new
    /// column and leaves a fresh tab of the same kind (Dock Column on a
    /// screen with one tab).
    case tabColumnRespawn = "tab-column-respawn-v1"
    /// `restart-tab`: a terminal tab whose shell ended restarts under the
    /// same terminal id (Unix daemons).
    case tabRestart = "tab-restart-v1"
    /// `restart-tab` of a keep-layout tab starts its shell in the kept
    /// directory and ends the keep (an exit closes the tab again, no relaunch
    /// on the next connect): the only way kept tabs restart (Unix daemons).
    case tabRestartKeptLayout = "tab-restart-kept-layout-v1"
    /// `park-tabs`: terminal tabs keep their place while their shells end,
    /// as keep-layout tabs; `restart-tab` starts each again (Unix daemons).
    case tabPark = "tab-park-v1"
    /// `create-terminal {detached: true}`: a kept terminal with no tab.
    case detachedTerminals = "detached-terminals-v1"
    /// Personal state kept only on the home (local) session
    /// (plans/cmux-next/data-model.md): a remote daemon never needs these.
    /// Per-terminal themes in personal state (`set-personal-terminal`).
    case personalTerminals = "personal-terminals-v1"
    /// Browser profile records in personal state (plans/cmux-next/data-model.md 5).
    case browserProfiles = "browser-profiles-v1"
    /// Bookmarks per browser profile in personal state (plans/cmux-next/bookmarks.md).
    case bookmarks = "bookmarks-v1"
    /// A bookmark folder's `icon` on `list-bookmarks` and `update-bookmark` (null clears).
    case bookmarkIcon = "bookmark-icon-v1"
    /// The daemon history module (react-pages.md H3): page visits, the merged read model,
    /// removal with restore ids, and `history-changed`.
    case history = "history-v1"
    /// Local conversations owned by the daemon (Home, plans/cmux-next/home.md):
    /// the `conversation-*` commands and `conversation-changed`/`conversation-typing` events.
    case localConversations = "local-conversations-v1"
    /// `conversation-draft` events on `subscribe`: the Chief's running reply,
    /// which Home grows in the Chief's bubble until the reply is posted.
    case conversationDraftEvents = "conversation-draft-events-v1"
    /// A Chief's live run (Conversations/ChiefLiveEvents.swift): `conversation-live` / `cloud-conversation-live`
    /// frames and snapshots, and the run-changed events whose end and reply key end its live text.
    case chiefLive = "chief-live-v1"
    case cloudChiefLive = "cloud-chief-live-v1"
    case conversationRuns = "conversation-runs-v1"
    case conversationRunAnswers = "conversation-run-answers-v1"
    case cloudConversationRuns = "cloud-conversation-runs-v1"
    /// `cloud-conversation-typing` command and event: typing in Cloud DMs and groups.
    case cloudConversationTyping = "cloud-conversation-typing-v1"
    /// `workspace.ensure_home` and the home workspace (`kind: home`; home.md 7).
    case workspaceKind = "workspace-kind-v1"
    /// `workspace.agent_folder.set` and `extra.agent_folder` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    /// An older daemon kept running across an app update lacks it: Choose Folder… asks for a restart.
    case workspaceAgentFolder = "workspace-agent-folder-v1"
    /// `workspace.agent_start.get`: the store's one answer for where a new agent chat starts
    /// (cx-9aps). An older daemon lacks it; the pane then decides as before (compatibility only).
    case workspaceAgentStart = "workspace-agent-start-v1"
    /// Conversation tabs: `new-conversation-tab` and the `conversation` tab kind.
    /// Echoed so the daemon sends the canonical kind instead of `browser`.
    case conversationTabs = "conversation-tabs-v1"
    /// Agent chat tabs on the store: the `agent_session` source of a conversation tab and
    /// `bind-conversation-tab-session` (cmux-tui/spec/commands.md, new-conversation-tab).
    case agentSessionTabs = "agent-session-tabs-v1"
    /// Canonical conversation kinds in closed history; live support alone is insufficient.
    case closedConversationTabs = "closed-conversation-tabs-v1"
    /// Agent chat tabs of another machine's store: attach, replay, prompt and answer
    /// permissions through that machine's session daemon (cmux-tui/spec/commands.md
    /// "Agent session attach").
    case agentSessionAttach = "agent-session-attach-v1"
    /// Read-only observation of a remote agent session. An observer never falls back to the
    /// writable attach capability (`cmux-tui/spec/commands.md`, `agent-session-observe`).
    case agentSessionObserve = "agent-session-observe-v1"
    /// `agent-session-start`: the session daemon starts a new chat for one of its agent tabs in
    /// its own machine's acpmux (policy `ask`) and binds it (cmux-tui/spec/commands.md
    /// "agent-session-start"). A chat in a remote workspace starts only through it; without it
    /// the app asks to update that machine's cmux-tui, never starts on this Mac.
    case agentSessionStart = "agent-session-start-v1"
    /// `agent-session-start` accepts an omitted cwd and creates a Cloud chat folder.
    case agentSessionStartNoCwd = "agent-session-start-no-cwd-v1"
    /// The folder trust of a chat of that machine (`agent-session-trust`, cx-1bhjj): the person's
    /// Trust answer for a folder there, recorded in that machine's acpmux.
    case agentSessionTrust = "agent-session-trust-v1"
    /// `agent-session-start` takes `require_person_key` and answers the typed
    /// `agent_session.needs_keyed_start` (cx-0w0jj): that machine's daemon says whether a keyed
    /// restart of its acpmux can lose nothing, so the app no longer reads the acpmux status.
    case agentSessionStartKeyedReason = "agent-session-start-keyed-reason-v1"
    case agentSessionStartVMKind = "agent-session-start-vm-kind-v1"
    case agentSessionStartModel = "agent-session-start-model-v1"
    case agentSessionTrustVMKind = "agent-session-trust-vm-kind-v1"
    /// `agent-session-folders`: that machine's work folder (`$HOME/work`) and its folders, so a
    /// chat there with no folder starts in the work folder and Choose folder lists that machine's.
    case agentSessionFolders = "agent-session-folders-v1"
    /// `agent-session-children`: an attached chat's daemon lists the chats its session started on
    /// that machine and streams their changes, and a listed child opens in a tab of that machine
    /// (a Cloud VM chat's sub-sessions on the Mac). Without it the chat shows no children.
    case agentSessionChildren = "agent-session-children-v1"
    case agentSessionPresence = "agent-session-presence-v1"
    /// `agent-session-set-model`, `-set-mode` and `-set-config`: the person's model, mode and
    /// option picks in a chat on that machine. Without it those picks say to update its cmux-tui.
    case agentSessionSettings = "agent-session-settings-v1"
    /// `agent-session-login`: a Cloud chat's own sign-in on that machine (the failed turn's
    /// sign-in card), as acpmux's `_acpmux/agent_login/*` on the tab's own session.
    case agentSessionLogin = "agent-session-login-v1"
    /// Page tabs on the store: the `page` source of a conversation tab (App Store, Settings,
    /// Debug Settings), so they move and split like any tab (cmux-tui/spec/commands.md).
    case pageTabs = "page-tabs-v1"
    /// A page tab's `route` (`page-tab-route-v1`): what the page shows (a viewer's file or
    /// folder), kept with the tab and in its closed-history record, so a reopened or relaunched
    /// page tab shows it again (plans/cmux-next/reopen-closed.md 3.0).
    case pageTabRoute = "page-tab-route-v1"
    /// App workspaces (`workspace.ensure_app`, `Workspace.app`, `Tab.app`).
    case appScreens = "app-screens-v1"
    /// `conversation-search` on the local conversation owner.
    case conversationSearch = "conversation-search-v1"
    /// `thread_root` on messages, and a send that moves the sender's own read cursor (spec `conversation-op`).
    case conversationThreads = "conversation-threads-v1"
    /// `conversation-thread` (`cloud-conversation-thread` too) and the owner's `threads` stats on snapshot and history pages.
    case conversationThread = "conversation-thread-v1"
    /// `conversation-inbox-op` (the caller's own pins and marks), `home-inbox` (the Home list rows), `chief-changed` events.
    case conversationInboxState = "conversation-inbox-state-v1"
    case homeInbox = "home-inbox-v1"
    case chiefEvents = "chief-events-v1"
    /// Cloud conversations through the daemon (plans/cmux-next/home-cloud-proxy.md): `cloud-session-*`, `cloud-inbox-*`, `cloud-conversation-*`
    /// and their `cloud-*` events, only with the cloud transport installed. `cloudHostReplica`: object-sync DESIGN.md phase 3, verified app only.
    case cloudConversations = "cloud-conversations-v1"
    case cloudHostReplica = "cloud-host-replica-v1"
    /// `cloud-attachment-upload` and `cloud-attachment-read`: attachments of Cloud conversations
    /// through the daemon's lease (advertised with `cloud-conversations-v1`).
    case cloudAttachments = "cloud-attachments-v1"
    /// `cloud-session-set {auth: "tailscale"}` and `cloud-selfhost-info`: a self-hosted chat server
    /// reached over Tailscale with no token (`home.server`, dm-group-chat-DESIGN.md section 4.5).
    case cloudSelfHost = "cloud-selfhost-v1"
    /// `page-credential`: the verified app gets a credential for its own page, which then gets
    /// the person's Cloud lease (`ws-cloud-conversations-v1`, cx-hnmbt.4).
    case pageCredential = "page-credential-v1"
    /// `page-credential {page}`: any trusted local connection gets a single-use credential bound
    /// to one page (its Origin only, never the Cloud lease); the Chief home's owner, whose app
    /// connection is not the verified app, hands the Channels page one.
    case scopedPageCredential = "page-credential-scoped-v1"
    /// `ws-listen`: a running owner opens its loopback page listener on request (cx-hnmbt.5); an older owner is handed off to the bundled build.
    case wsListen = "ws-listen-v1"
    /// `ws-listen {allow_origins}`: the listener admits every first-party page origin
    /// (cx-hnmbt.10); an owner without it gets the Channels origin only.
    case wsListenOrigins = "ws-listen-origins-v1"
    /// Groups placed among the loose personal workspaces: `top_index` on
    /// `list-personal` groups and on `workspace_group.update`, and a personal
    /// row for every new workspace (cmux-tui `personal_order.rs`).
    case personalMixedOrder = "personal-mixed-order-v1"
    /// `icon` on `workspace_group.update` and on personal groups.
    case workspaceGroupIcon = "workspace-group-icon-v1"
    /// `pinned` (saved) on `workspace_group.update` and on personal groups.
    case workspaceGroupPin = "workspace-group-pin-v1"
    /// `icon` on screen groups and saved screen groups, on
    /// `screen_group.update` and raw `update-screen-group` (null clears).
    case screenGroupIcon = "screen-group-icon-v1"
    /// `icon` on tab groups and saved tab groups, on `tab_group.update` and
    /// raw `update-tab-group` (null clears).
    case tabGroupIcon = "tab-group-icon-v1"
    /// `icon` on each session record of the home session registry
    /// (`list-personal`), set and cleared by raw `set-session-icon`: the
    /// icon the sidebar draws for that machine. Home daemon only.
    case sessionIcon = "session-icon-v1"
    /// `attachment` parts and their bytes on the local conversation owner:
    /// `conversation-attachment-upload` and `conversation-attachment-read`.
    case localAttachments = "local-attachments-v1"
    /// `link_preview` parts on the local conversation owner (a sender sends
    /// plain text to a daemon without it).
    case linkPreview = "link-preview-v1"
    /// `chief-inspect`: the Chief memory inspector's read-only API on the
    /// brain's daemon (advertised when the daemon knows the brain's tools socket).
    case chiefInspect = "chief-inspect-v1"
    /// A replay taken inside an escape sequence carries the unfinished bytes
    /// in `pending` (main PR 15533). Without it, cmux-tui ends a view's attach
    /// stream whenever a PTY resize happens mid-sequence (a relaunch resizes
    /// every restored terminal), and the view freezes.
    case terminalPendingSequence = "terminal-pending-sequence-v1"
    /// Finished shell commands (OSC 133) stored as deletable rows with a
    /// retention once `set-terminal-command-history` turns it on; read with
    /// `list-terminal-commands`, deleted with `delete-terminal-commands`
    /// (plans/cmux-next/history.md 6).
    case terminalCommandHistory = "terminal-command-history-v1"
    /// `sidebar_layout.get|update` (plans/cmux-next/sidebar-sections.md 5;
    /// cmux-tui PR #16842).
    case sidebarLayout = "sidebar-layout-v1"
    /// The one sidebar document (`sidebar.get|move|pin|unpin|apply|adopt`,
    /// `sidebar_item`/`sidebar_section` on `session.events`;
    /// .cmux-scratch/sidebar-rewrite/CONTRACT.md). Without it the sidebar
    /// keeps the personal order and `sidebar-layout-v1` path.
    case sidebarDoc = "sidebar-doc-v1"
    /// The client orders rows from the sidebar document only, so the daemon
    /// sends no `workspace_placement` restatement (cmux-tui
    /// state/placement_shift.rs). Echoed only by a connection whose
    /// configuration says this build orders rows from the document
    /// (``DaemonConnectionConfiguration/echoesPlacementShift``), never advertised alone.
    case placementShift = "placement-shift-v1"
    /// `palette_usage.get|record|import`: the user's palette usage history
    /// and learned picks, owned by the daemon (plans/cmux-next/palette-ranking.md 5.3).
    case paletteUsage = "palette-usage-v1"
    /// `browser.devices.*` and `browser.tab.emulate*`: Chrome's device toolbar
    /// list and each browser tab's emulation (`extra.emulation`), owned by the daemon (cx-ocbf3).
    case browserDevices = "browser-devices-v1"
    /// `browser.tab.emulate {fit}`: Fit as 16:9 Desktop (cx-va1wd).
    case browserFit = "browser-fit-v1"
    /// `browser.tab.emulate {fit: "1280"}`: Fit as Desktop (1280) (cx-2ftlq).
    case browserFitWidth = "browser-fit-width-v1"
    /// keybindings.json owned by the daemon (`keybindings.*`, cx-9ce.17).
    case keybindings = "keybindings-v1"
    /// `put-blob`/`get-blob`: the owner's icon asset store, and `image:`/`svg:`
    /// icon values naming a stored asset on workspace, screen, room and profile icons.
    case iconAssets = "icon-assets-v1"
    /// `project.list|observe|add|update|remove|sync`: the device project list
    /// (plans/cmux-next/projects.md).
    case projectList = "project-list-v1"
    /// `move-tab-to-split` `respawn`: splitting a pane with its only tab
    /// spawns a new tab of the same kind in the source pane, in the same
    /// owner op (plans/cmux-next/layout-invariants.md).
    case tabSplitRespawn = "tab-split-respawn-v1"
    /// `move-tab-to-split` `keep_focus`: the new pane does not take focus (a
    /// pane the app opens for a subagent while the user types in the chat).
    case tabSplitKeepFocus = "tab-split-keep-focus-v1"
    /// `workspace.create` `focus`: a created workspace becomes the focused
    /// one only when asked (the app asks for the person's creations).
    case workspaceCreateFocus = "workspace-create-focus-v1"
    /// Additive shapes the app asks for through `set-client-info`: view
    /// identity on attach, creation receipts, caller-chosen creation attempt
    /// keys, and per-terminal color overrides.
    case attachIdentity = "attach-identity-v1"
    case creationReceipts = "creation-receipts-v1"
    case creationAttemptKeys = "creation-attempt-keys-v1"
    case terminalColorOverrides = "terminal-color-overrides-v1"
    /// Snapshot attach with scrollback: READY snapshots followed by their
    /// history as raw-DEFLATE `snapshot {phase: "history"}` chunks
    /// (`TerminalAttachment`; plans/cmux-next/ghostty-next.md 2.2).
    case terminalSnapshotHistory = "terminal-snapshot-history-v1"
    /// A READY cut exactly at a host resize, restored with the view's own
    /// reflowed history (S2c; plans/cmux-next/ghostty-next.md 2.2).
    case terminalSnapshotLocalHistory = "terminal-snapshot-local-history-v1"
    /// The Kitty image replay after a plain READY (S3k).
    case terminalSnapshotImages = "terminal-snapshot-images-v1"
    /// The OSC 52 clipboard-read broker: `terminal-clipboard-subscribe`,
    /// `terminal-clipboard-reply` and the targeted read events
    /// (`TerminalClipboardBroker`; plans/cmux-next/ghostty-config.md).
    case terminalClipboardRead = "terminal-clipboard-read-v1"
    /// The page relay's origin claim (`ResourceRelay.originClaimCapability`,
    /// `ClientHello.originClaimCapability`).
    case originClaim = "origin-claim-v1"
    /// Page ids on page relays and the per-page allow list (`page-router-v1`;
    /// `DaemonClientRole.pageRouterCapability`).
    case pageRouter = "page-router-v1"
    /// `read-session-journal` for agent history (`AgentHistory`).
    case sessionJournal = "session-journal-v1"
    /// Per-terminal resource usage (`TerminalResourcesRequest.capability`).
    case terminalResources = "terminal-resources-v1"
    /// Owner machine metadata on `identify` (`HandshakeLines`).
    case machineIdentity = "machine-identity-v1"
    /// Registered `agent_cli` app providers (`AppProviderSession`).
    case agentCLIAppProvider = "agent-cli-app-provider-v1"
    /// Agent inventory invalidation events for app providers (`AppProviderSession`).
    case agentCLIAppInvalidation = "agent-cli-app-invalidation-v1"
    /// Admission receipts on the agent inventory watch (`DaemonReadyConnection`).
    case agentInventoryWatchAdmission = "agent-inventory-watch-admission-v1"
    /// Stash, a native OneTab (`stash.*`; `StateResourceClient+Stash.swift`).
    case stash = "stash-v1"
    /// Whole workspaces in a stash: `stash.create {workspaces}` closes them with their terminals
    /// (`StateResourceClient.stashWorkspaces`), and their members list with `kind: "workspace"`.
    case stashWorkspaces = "stash-workspaces-v1"
    /// `layout.bulk` close: one gesture over several panes, screens or workspaces is one commit and
    /// one closed-history group, so one Reopen Closed brings all of them back
    /// (`StateResourceClient.closeBulk`).
    case layoutBulk = "layout-bulk-v1"

    /// Which list a capability is in.
    public enum Tier: Sendable {
        /// The GUI refuses a daemon without it.
        case required
        /// The bundled daemon serves it (check-daemon-capabilities.sh fails the build when it does
        /// not); the GUI still checks it per daemon with `DaemonIdentity.supports`.
        case optional
        /// App code waiting for a daemon half that no branch has yet; the list only shrinks.
        case unservedByBundledDaemon
    }

    /// The list this capability is in. The `switch` has no `default`, so the compiler makes every
    /// new case pick one (scripts/cmux-next/check-daemon-capabilities-fresh.py refuses a `default`).
    public var tier: Tier {
        switch self {
        case .workspaceRegistry, .viewportSplits, .viewportColumnResize, .layoutUndo, .viewAttachmentLease,
             .viewAttachmentDetach, .attachInitialSize:
            return .required
        case .workspaceGroups, .workspaceMetadata, .workspaceNameSource, .tabMetadata, .frontendBrowserTabs,
             .frontendBrowserTabKeys, .frontendBrowserHistory, .frontendBrowserTabProfile, .tabDrag, .sharedSizing,
             .tabWorkspaceName, .notificationAck, .feedLocalOwner, .tabGroups, .savedTabGroups, .workspacePin,
             .workspaceChecklist, .notificationMarkUnread, .tabMarkUnread, .tabAttention, .tabAttentionRequestID, .workspaceDescription, .workspaceStatus,
             .screenMetadata, .screenGroups, .stateResources, .windowRecords, .terminalEnv, .terminalPlacementEnv,
             .splitClientKeys, .splitClientSplitID, .rowClientKeys, .rowClientReplay, .conversationTabSplit,
             .terminalInputWhileCreating, .terminalReap, .resumeCommand, .terminalReaperActive,
             .endTerminalsKeepLayout, .batchClose, .sendExpectForeground, .closeReason, .closeWorkspaceIfEmpty,
             .browserHostProvider, .frontendBrowserActivate, .frontendBrowserInsertAfter, .loopbackForward,
             .browserRuntime, .notificationSource, .terminalShellArgs, .terminalFrontendShellIntegration,
             .launchSnapshot, .profiles, .personalRemoteLocalhost, .sessionIdentity, .remoteTerminalTabs,
             .dockColumns, .edgeDocks, .dockColumnRole, .dockColumnSplitDown, .pinnedDock, .pinnedDockAlone, .rows, .columnMove, .columnLeft,
             .tabColumnRespawn, .tabRestart, .tabRestartKeptLayout, .tabPark, .detachedTerminals, .personalTerminals,
             .browserProfiles, .bookmarks, .bookmarkIcon, .history, .localConversations, .conversationDraftEvents,
             .chiefLive, .cloudChiefLive, .conversationRuns, .conversationRunAnswers, .cloudConversationRuns, .cloudConversationTyping,
             .workspaceKind, .workspaceAgentFolder, .workspaceAgentStart, .conversationTabs, .agentSessionTabs, .closedConversationTabs,
             .agentSessionAttach, .agentSessionObserve, .agentSessionStart, .agentSessionStartNoCwd, .agentSessionTrust,
             .agentSessionStartKeyedReason, .agentSessionStartVMKind, .agentSessionStartModel, .agentSessionTrustVMKind, .agentSessionFolders,
             .agentSessionChildren, .agentSessionPresence, .agentSessionSettings, .agentSessionLogin, .pageTabs, .pageTabRoute, .appScreens,
             .conversationSearch, .conversationThreads, .conversationThread, .conversationInboxState, .homeInbox,
             .chiefEvents, .cloudConversations, .cloudHostReplica, .cloudAttachments, .cloudSelfHost,
             .pageCredential, .scopedPageCredential, .wsListen, .wsListenOrigins, .personalMixedOrder,
             .workspaceGroupIcon, .workspaceGroupPin, .screenGroupIcon, .tabGroupIcon, .sessionIcon,
             .localAttachments, .linkPreview, .chiefInspect, .terminalPendingSequence, .terminalCommandHistory,
             .sidebarLayout, .sidebarDoc, .placementShift, .paletteUsage, .browserDevices, .browserFit,
             .browserFitWidth, .keybindings, .iconAssets, .projectList, .tabSplitRespawn, .tabSplitKeepFocus,
             .workspaceCreateFocus, .attachIdentity, .creationReceipts, .creationAttemptKeys,
             .terminalColorOverrides, .terminalSnapshotHistory, .terminalSnapshotLocalHistory,
             .terminalSnapshotImages, .terminalClipboardRead, .originClaim, .pageRouter, .sessionJournal,
             .terminalResources, .machineIdentity, .agentCLIAppProvider, .agentCLIAppInvalidation,
             .agentInventoryWatchAdmission, .stash, .stashWorkspaces, .layoutBulk:
            return .optional
        }
    }

    /// The wire names of the capabilities the GUI cannot work without.
    public static let required: [String] = names(in: .required)

    /// Capabilities the bundled daemon must serve. The bundled cmux-tui is
    /// built from this checkout's own cmux-tui tree
    /// (scripts/cmux-next/pin-cmux-tui.sh), and
    /// scripts/cmux-next/check-daemon-capabilities.sh fails the build when it
    /// does not serve one of these or `required`. The GUI still checks each
    /// with `DaemonIdentity.supports`, for remote and older daemons.
    public static let optional: [String] = names(in: .optional)

    /// App code waiting for a daemon half that no branch has yet. Each
    /// feature shows disabled with its reason (or refuses with it) while the
    /// bundled daemon lacks the capability. The list only shrinks
    /// (DaemonCapabilityExportTests): new app features land with their
    /// daemon half, and check-daemon-capabilities.sh fails once the bundled
    /// daemon serves an entry, so it moves to `optional`.
    public static let unservedByBundledDaemon: [String] = names(in: .unservedByBundledDaemon)

    /// Served only by the local (home) daemon; a remote machine's daemon never needs them.
    public static let homeOnly: [String] = names([.profiles, .personalTerminals, .browserProfiles, .bookmarks,
                                                  .localConversations, .sessionIcon])
    /// Written to the local daemon's personal rows instead of each machine's
    /// daemon once the local daemon serves `profiles-v1`.
    public static let personalOnHome: [String] = names([.workspaceGroups, .savedTabGroups])

    /// Whether the bundled daemon (this tree's cmux-tui) serves `capability`:
    /// a daemon without it is an older build, and restarting cmux updates it.
    public static func isServedByBundledDaemon(_ capability: String) -> Bool {
        guard let known = DaemonCapability(rawValue: capability) else { return false }
        return known.tier != .unservedByBundledDaemon
    }

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    /// `terminalFrontendShellIntegration` is not in it: only a connection
    /// that resolves the integration echoes it (`handshakeCapabilities`).
    /// `sharedSizing` is not either: a terminal attachment that names its device adds it
    /// (`TerminalAttachment.attach(device:)`); other connections only read it from `identify`.
    /// `placementShift` only with the sidebar document (`handshakeCapabilities`).
    public static let advertised: [String] = (required + optional + unservedByBundledDaemon).filter {
        !notAdvertised.contains($0)
    }
    private static let notAdvertised: Set<String> = Set(names([.terminalFrontendShellIntegration, .placementShift,
                                                               .sharedSizing, .agentSessionPresence]))

    /// What a connection echoes in `set-client-info`.
    ///
    /// - Parameters:
    ///   - advertised: The capabilities the connection advertises.
    ///   - resolvesShellIntegration: The connection resolves Ghostty's shell integration itself.
    ///   - echoesPlacementShift: This build orders sidebar rows from the sidebar document only
    ///     (the App passes `SidebarMirror.isLinked` from its composition root).
    public static func handshakeCapabilities(_ advertised: [String], resolvesShellIntegration: Bool,
                                             echoesPlacementShift: Bool = false) -> [String] {
        // The document path echoes `placement-shift-v1` together with `sidebar-doc-v1`.
        let document = echoesPlacementShift && advertised.contains(Self.sidebarDoc.rawValue) ? [Self.placementShift.rawValue] : []
        let shell = resolvesShellIntegration ? [Self.terminalFrontendShellIntegration.rawValue] : []
        return advertised + shell + document
    }

    private static func names(_ capabilities: [DaemonCapability]) -> [String] { capabilities.map(\.rawValue) }
    private static func names(in tier: Tier) -> [String] { names(allCases.filter { $0.tier == tier }) }
}
