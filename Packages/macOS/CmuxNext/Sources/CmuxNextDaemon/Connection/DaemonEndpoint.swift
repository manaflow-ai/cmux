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

/// Capabilities the GUI relies on (plans/cmux-next/cmux-tui-contract.md 2.2).
public struct DaemonCapabilities: Sendable {
    /// The catalog has no instances: every capability and list is a static declaration.
    private init() {}

    public static let required: [String] = [
        "workspace-registry-v1",
        "viewport-splits-v1",
        "viewport-column-resize-v1",
        "layout-undo-v1",
        "view-attachment-lease-v1",
        "view-attachment-detach-v1",
        "attach-initial-size",
    ]

    /// Additive protocol 12 capabilities from cmux-tui PR 15518
    /// (cmux-tui/spec/commands.md). The GUI hides the matching features when
    /// a daemon lacks them (`DaemonIdentity.supports`).
    public static let workspaceGroups = "workspace-groups-v1"
    public static let workspaceMetadata = "workspace-metadata-v1"
    public static let workspaceNameSource = "workspace-name-source-v1"
    public static let tabMetadata = "tab-metadata-v1"
    public static let frontendBrowserTabs = "frontend-browser-tabs-v1"
    public static let frontendBrowserTabKeys = "frontend-browser-tab-keys-v1" // idempotency_key on new-frontend-browser-tab
    /// A frontend browser tab's back/forward entries and scroll positions,
    /// stored opaque and outside the journal (`set-`/`get-frontend-browser-history`).
    public static let frontendBrowserHistory = "frontend-browser-history-v1"
    /// `profile_id` on `update-frontend-browser-tab`: the tab moves to another browser profile in place.
    public static let frontendBrowserTabProfile = "frontend-browser-tab-profile-v1"
    public static let tabDrag = "tab-drag-v1"
    /// `set-size-counts` (protocol 12): a hidden view keeps its lease and stops counting toward
    /// the grid (`TerminalAttachment.sendHidden`). The GUI reads it from `identify`; it does not
    /// advertise it back (that would subscribe its streams to `size-state` events).
    public static let sharedSizing = "shared-sizing-v1"
    /// `name` on `move-tab-to-new-workspace`: the new workspace takes the
    /// moved tab's name in the same commit (else the app renames after).
    public static let tabWorkspaceName = "tab-workspace-name-v1"
    public static let notificationAck = "notification-ack-v1"
    /// The daemon's local feed owner (plans/cmux-next/feed.md 9.1): every
    /// notification is also a local feed item, selection never clears unread,
    /// `ack-tab-notifications` reports `refused` items, and the
    /// `feed-local-*` commands let the app hand items to the cloud owner.
    public static let feedLocalOwner = "feed-local-owner-v1"
    public static let tabGroups = "tab-groups-v1"
    public static let savedTabGroups = "saved-tab-groups-v1"
    /// The sidebar workspace pin: `pinned` on `set-workspace-metadata` and workspaces.
    public static let workspacePin = "workspace-pin-v1"
    /// Each workspace's checklist (`workspace_checklist.*` and the `workspace_checklist` state resource).
    public static let workspaceChecklist = "workspace-checklist-v1"
    /// The manual workspace unread mark: `marked_unread` on
    /// `set-workspace-metadata` and workspaces.
    public static let notificationMarkUnread = "notification-mark-unread-v1"
    /// The manual tab unread mark (Mark Tab Unread): `marked_unread` on
    /// `tab.update` and the tab's `extra.marked_unread`; no notification needed.
    public static let tabMarkUnread = "tab-mark-unread-v1"
    /// A workspace's description: `description` on `workspace.update` and the
    /// workspace's `extra.description` (Edit / Clear Workspace Description).
    public static let workspaceDescription = "workspace-description-v1"
    /// A workspace's manual task status (classic lanes): `task_status` on
    /// `workspace.update` and the workspace's `extra.task_status`.
    public static let workspaceStatus = "workspace-status-v1"
    /// Screen color, icon, pin, and order (`set-screen-metadata`,
    /// `set-screen-pinned`, `move-screen`; `screen.update` and `screen.move`
    /// with `stateResources`, over the same storage).
    public static let screenMetadata = "screen-metadata-v1"
    /// Screen groups and saved screen groups (`screen_group.*` with
    /// `stateResources`).
    public static let screenGroups = "screen-groups-v1"
    /// The state resources over `cmux.protocol/2` (state-ownership.md steps
    /// A and B): closed history, ephemeral workspaces, workspace status,
    /// screen metadata and groups, tab records, terminal progress, and the
    /// v2 state mutations, mirrored through `session.events`. The daemon
    /// advertises it in `identify` (`DaemonStore.servesStateResources`).
    public static let stateResources = "state-resources-v1"
    /// `window_record.put` / `.delete` / `.list`: one record per app window, keyed by install and
    /// window id. The app mirrors its windows there so closed history knows each group's window,
    /// and a window it closes becomes a closed-history `window` group (reopen-closed.md 4).
    public static let windowRecords = "window-records-v1"
    /// Per-terminal `env` on `new-tab`, `split`, `create-terminal`; `cwd` on `split`.
    public static let terminalEnv = "terminal-env-v1"
    /// Caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and
    /// `new-pane-right`; `cwd`/`env` on the last two (cmux-tui PR 15600).
    public static let terminalPlacementEnv = "terminal-placement-env-v1"
    /// Client-minted `pane_id` / `tab_id` on `split`, `new-pane` and `new-pane-right`, keyed
    /// retries (plans/cmux-next/remote-state-ownership.md S1).
    public static let splitClientKeys = "split-client-keys-v1"
    /// `split` takes a client-minted `split_id` and layout split nodes carry `split_id`.
    public static let splitClientSplitID = "split-client-split-id-v1"
    /// `new-conversation-tab {pane, split}`: a chat or New Tab page tab in a new split, in one
    /// daemon commit and one `pane-added` delta (a person's Cmd-D, atomically).
    public static let conversationTabSplit = "conversation-tab-split-v1"
    /// `send {terminal_id}` to a terminal still being created: the daemon queues the input and
    /// writes it after the commit (cx-wb5.78, ``SendTerminalInputRequest``).
    public static let terminalInputWhileCreating = "terminal-input-while-creating-v1"
    /// The owner ends a terminal with no tab after a grace period unless it
    /// is kept: `keep` on creation, `set-terminal-keep`, and
    /// `shutdown-daemon end_terminals` (cmux-tui PR 15600).
    public static let terminalReap = "terminal-reap-v1"
    /// `terminal-resume-command`: a person's resume command for one terminal,
    /// typed on the new prompt when the daemon respawns it.
    public static let resumeCommand = "resume-command"
    /// The owner's reaper runs now (started with a reap grace, as the app
    /// starts it), so a detached terminal ends after the grace period. An
    /// owner started without a grace does not serve it.
    public static let terminalReaperActive = "terminal-reaper-active-v1"
    /// `keep_layout` on `shutdown-daemon end_terminals`: every terminal ends
    /// but placed ones keep their tabs, dead, so the next launch restarts a
    /// shell in each with the same splits (Quit's End Sessions, Keep Layout).
    public static let endTerminalsKeepLayout = "end-terminals-keep-layout-v1"
    /// `close-tabs` and `end_terminals` on the container closes: many tabs and
    /// the terminals they end close in one daemon commit.
    public static let batchClose = "batch-close-v1"
    /// `expect_foreground` on `send`: the daemon writes only while that program is still the
    /// terminal's foreground (the Chief pet's typed reply).
    public static let sendExpectForeground = "send-expect-foreground-v1"
    /// `reason` on `close-tabs` (`session_end`: not recorded in closed history).
    public static let closeReason = "close-reason-v1"
    /// `if_empty` on `close-workspace`: the daemon closes the workspace only
    /// when it has no tab at commit time (`workspace_not_empty` otherwise).
    public static let closeWorkspaceIfEmpty = "close-workspace-if-empty-v1"
    /// `browser-host-provider`: the verified app's credentials for the daemon's browser host.
    public static let browserHostProvider = "browser-host-provider-v1"
    /// `activate` on `new-frontend-browser-tab`: a background tab keeps the pane's active tab.
    public static let frontendBrowserActivate = "frontend-browser-activate-v1"
    /// `after` on `new-frontend-browser-tab`: a link's tab lands next to its opener.
    public static let frontendBrowserInsertAfter = "frontend-browser-insert-after-v1"
    /// Browser tabs reach the machine's loopback services over a dedicated
    /// connection (`LoopbackForwardClient`, plans/cmux-next/remote-localhost.md).
    public static let loopbackForward = "loopback-forward-v1"
    /// The daemon starts the remote browser host on its machine
    /// (`browser-runtime-*`, cx-2cob slice 2); the app reaches it through
    /// `loopbackForward` on the same connection (`LoopbackForwardClient`).
    public static let browserRuntime = "browser-runtime-v1"
    /// `source` on notifications (cli, terminal, agent, daemon), and OSC 9,
    /// OSC 777 and OSC 99 parsed by the daemon from every terminal's output
    /// (plans/cmux-next/notifications.md).
    public static let notificationSource = "notification-source-v1"
    /// `shell_args` on the terminal-creating commands, so bash and nushell
    /// get Ghostty's argv-based shell integration (`GhosttyShellIntegration`).
    public static let terminalShellArgs = "terminal-shell-args-v1"
    /// Echoed only by a connection whose terminals get Ghostty's shell
    /// integration from this app (`DaemonConnectionConfiguration
    /// .resolvesShellIntegration`): the daemon then starts the terminal's
    /// `SHELL` as given and adds no integration of its own (R92 bug 2).
    public static let terminalFrontendShellIntegration = "terminal-frontend-shell-integration-v1"
    /// `launch_snapshot_path` in `identify`: the daemon's last settled tree
    /// and window records, read before connecting (`LaunchSnapshot`).
    public static let launchSnapshot = "launch-snapshot-v1"
    /// Profiles (plans/cmux-next/data-model.md): the `*-profile` commands,
    /// `move-workspace-to-profile`, `profiles` in `list-workspaces`, and a
    /// `profile` field on workspaces, groups and saved tab groups.
    public static let profiles = "profiles-v1"
    /// `remote_localhost` on personal workspaces (`set-personal-workspace`,
    /// `list-personal`): the person's per-workspace remote-localhost choice.
    public static let personalRemoteLocalhost = "personal-remote-localhost-v1"
    /// `identify.session_id` and `identify.machine_name` (data-model.md 1.1);
    /// informational, the app falls back to `registry_id` and its own names.
    public static let sessionIdentity = "session-identity-v1"
    /// Remote-terminal tabs in a home layout: `new-remote-terminal-tab`,
    /// `update-remote-terminal-tab`, `remote-terminal-snapshot`, tab kind
    /// `remote-terminal` with `remote` (data-model.md 1.2b, 1.4, 1.5), and
    /// `terminal_resource_id` in the `set-terminal-keep` result.
    public static let remoteTerminalTabs = "remote-terminal-tabs-v1"
    /// Docked columns: `set-column-dock` and `columns[].dock`
    /// (plans/cmux-next/dock-column.md).
    public static let dockColumns = "dock-columns-v1"
    /// Top and bottom docks: `set-column-dock` and `move-tab-to-column`
    /// accept edges `top` and `bottom`, sent back as `columns[].dock`
    /// (plans/cmux-next/layout-model.md).
    public static let edgeDocks = "edge-docks-v1"
    /// `dock.role` (`agent_chat`) on `set-column-dock`, `move-tab-to-column`
    /// and `columns[].dock`: the agent chat column.
    public static let dockColumnRole = "dock-column-role-v1"
    /// Pinned dock columns (the Home dock): `set-column-dock` takes `pinned`,
    /// and the daemon keeps a pinned column's first tab and refuses other
    /// tabs into it unless its `allow_tabs` is on (`dock-column-pinned`).
    public static let pinnedDock = "pinned-dock-v1"
    /// A pinned column may be a screen's only column (Home's dock with nothing beside it):
    /// `move-tab-to-column` with a pinned dock moves a screen's only tab without `respawn`, and
    /// closing the last column beside it leaves the dock alone instead of being refused.
    public static let pinnedDockAlone = "pinned-dock-alone-v1"
    /// Rows: `new-row`, `set-row-heights` and `columns[].rows`
    /// (plans/cmux-next/rows.md). Without it no row op is sent.
    public static let rows = "rows-v1"
    /// `move-column`: a whole viewport column (every pane in it) moves one
    /// place left or right in one commit. Without it only a one-pane column
    /// moves, through `swap-pane`.
    public static let columnMove = "column-move-v1"
    /// `move-tab-to-column` `respawn`: a pane's only tab moves into a new
    /// column and leaves a fresh tab of the same kind (Dock Column on a
    /// screen with one tab).
    public static let tabColumnRespawn = "tab-column-respawn-v1"
    /// `restart-tab`: a terminal tab whose shell ended restarts under the
    /// same terminal id (Unix daemons).
    public static let tabRestart = "tab-restart-v1"
    /// `restart-tab` of a keep-layout tab starts its shell in the kept
    /// directory and ends the keep (an exit closes the tab again, no relaunch
    /// on the next connect): the only way kept tabs restart (Unix daemons).
    public static let tabRestartKeptLayout = "tab-restart-kept-layout-v1"
    /// `park-tabs`: terminal tabs keep their place while their shells end,
    /// as keep-layout tabs; `restart-tab` starts each again (Unix daemons).
    public static let tabPark = "tab-park-v1"
    /// `create-terminal {detached: true}`: a kept terminal with no tab.
    public static let detachedTerminals = "detached-terminals-v1"
    /// Personal state kept only on the home (local) session
    /// (plans/cmux-next/data-model.md): a remote daemon never needs these.
    /// Per-terminal themes in personal state (`set-personal-terminal`).
    public static let personalTerminals = "personal-terminals-v1"
    /// Browser profile records in personal state (plans/cmux-next/data-model.md 5).
    public static let browserProfiles = "browser-profiles-v1"
    /// Bookmarks per browser profile in personal state (plans/cmux-next/bookmarks.md).
    public static let bookmarks = "bookmarks-v1"
    /// A bookmark folder's `icon` on `list-bookmarks` and `update-bookmark` (null clears).
    public static let bookmarkIcon = "bookmark-icon-v1"
    /// The daemon history module (react-pages.md H3): page visits, the merged read model,
    /// removal with restore ids, and `history-changed`.
    public static let history = "history-v1"
    /// Local conversations owned by the daemon (Home, plans/cmux-next/home.md):
    /// the `conversation-*` commands and `conversation-changed`/`conversation-typing` events.
    public static let localConversations = "local-conversations-v1"
    /// `conversation-draft` events on `subscribe`: the Chief's running reply,
    /// which Home grows in the Chief's bubble until the reply is posted.
    public static let conversationDraftEvents = "conversation-draft-events-v1"
    /// A Chief's live run (Conversations/ChiefLiveEvents.swift): `conversation-live` / `cloud-conversation-live`
    /// frames and snapshots, and the run-changed events whose end and reply key end its live text.
    public static let chiefLive = "chief-live-v1"
    public static let cloudChiefLive = "cloud-chief-live-v1"
    public static let conversationRuns = "conversation-runs-v1"
    public static let cloudConversationRuns = "cloud-conversation-runs-v1"
    /// `cloud-conversation-typing` command and event: typing in Cloud DMs and groups.
    public static let cloudConversationTyping = "cloud-conversation-typing-v1"
    /// `workspace.ensure_home` and the home workspace (`kind: home`; home.md 7).
    public static let workspaceKind = "workspace-kind-v1"
    /// `workspace.agent_folder.set` and `extra.agent_folder` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    /// An older daemon kept running across an app update lacks it: Choose Folder… asks for a restart.
    public static let workspaceAgentFolder = "workspace-agent-folder-v1"
    /// `workspace.agent_start.get`: the store's one answer for where a new agent chat starts
    /// (cx-9aps). An older daemon lacks it; the pane then decides as before (compatibility only).
    public static let workspaceAgentStart = "workspace-agent-start-v1"
    /// Conversation tabs: `new-conversation-tab` and the `conversation` tab kind.
    /// Echoed so the daemon sends the canonical kind instead of `browser`.
    public static let conversationTabs = "conversation-tabs-v1"
    /// Agent chat tabs on the store: the `agent_session` source of a conversation tab and
    /// `bind-conversation-tab-session` (cmux-tui/spec/commands.md, new-conversation-tab).
    public static let agentSessionTabs = "agent-session-tabs-v1"
    /// Agent chat tabs of another machine's store: attach, replay, prompt and answer
    /// permissions through that machine's session daemon (cmux-tui/spec/commands.md
    /// "Agent session attach").
    public static let agentSessionAttach = "agent-session-attach-v1"
    /// Read-only observation of a remote agent session. An observer never falls back to the
    /// writable attach capability (`cmux-tui/spec/commands.md`, `agent-session-observe`).
    public static let agentSessionObserve = "agent-session-observe-v1"
    /// `agent-session-start`: the session daemon starts a new chat for one of its agent tabs in
    /// its own machine's acpmux (policy `ask`) and binds it (cmux-tui/spec/commands.md
    /// "agent-session-start"). A chat in a remote workspace starts only through it; without it
    /// the app asks to update that machine's cmux-tui, never starts on this Mac.
    public static let agentSessionStart = "agent-session-start-v1"
    /// The folder trust of a chat of that machine (`agent-session-trust`, cx-1bhjj): the person's
    /// Trust answer for a folder there, recorded in that machine's acpmux.
    public static let agentSessionTrust = "agent-session-trust-v1"
    /// `agent-session-adopt`: the session daemon binds a chat that already runs in its own
    /// machine's acpmux to one of its agent tabs and says whether its mode asks (cmux-tui/spec/commands.md
    /// "agent-session-adopt"): how the app opens another machine's running chat as a workspace.
    public static let agentSessionAdopt = "agent-session-adopt-v1"
    /// `agent-session-start` takes `require_person_key` and answers the typed
    /// `agent_session.needs_keyed_start` (cx-0w0jj): that machine's daemon says whether a keyed
    /// restart of its acpmux can lose nothing, so the app no longer reads the acpmux status.
    public static let agentSessionStartKeyedReason = "agent-session-start-keyed-reason-v1"
    /// `agent-session-children`: an attached chat's daemon lists the chats its session started on
    /// that machine and streams their changes, and a listed child opens in a tab of that machine
    /// (a Cloud VM chat's sub-sessions on the Mac). Without it the chat shows no children.
    public static let agentSessionChildren = "agent-session-children-v1"
    /// Page tabs on the store: the `page` source of a conversation tab (App Store, Settings,
    /// Debug Settings), so they move and split like any tab (cmux-tui/spec/commands.md).
    public static let pageTabs = "page-tabs-v1"
    /// A page tab's `route` (`page-tab-route-v1`): what the page shows (a viewer's file or
    /// folder), kept with the tab and in its closed-history record, so a reopened or relaunched
    /// page tab shows it again (plans/cmux-next/reopen-closed.md 3.0).
    public static let pageTabRoute = "page-tab-route-v1"
    /// App workspaces (`workspace.ensure_app`, `Workspace.app`, `Tab.app`).
    public static let appScreens = "app-screens-v1"
    /// `conversation-search` on the local conversation owner.
    public static let conversationSearch = "conversation-search-v1"
    /// `thread_root` on messages, and a send that moves the sender's own read cursor (spec `conversation-op`).
    public static let conversationThreads = "conversation-threads-v1"
    /// `conversation-thread` (`cloud-conversation-thread` too) and the owner's `threads` stats on snapshot and history pages.
    public static let conversationThread = "conversation-thread-v1"
    /// `conversation-inbox-op` (the caller's own pins and marks), `home-inbox` (the Home list rows), `chief-changed` events.
    public static let conversationInboxState = "conversation-inbox-state-v1"
    public static let homeInbox = "home-inbox-v1"
    public static let chiefEvents = "chief-events-v1"
    /// Cloud conversations through the daemon (plans/cmux-next/home-cloud-proxy.md): `cloud-session-*`, `cloud-inbox-*`, `cloud-conversation-*`
    /// and their `cloud-*` events, only with the cloud transport installed. `cloudHostReplica`: object-sync DESIGN.md phase 3, verified app only.
    public static let cloudConversations = "cloud-conversations-v1"
    public static let cloudHostReplica = "cloud-host-replica-v1"
    /// `cloud-attachment-upload` and `cloud-attachment-read`: attachments of Cloud conversations
    /// through the daemon's lease (advertised with `cloud-conversations-v1`).
    public static let cloudAttachments = "cloud-attachments-v1"
    /// `cloud-session-set {auth: "tailscale"}` and `cloud-selfhost-info`: a self-hosted chat server
    /// reached over Tailscale with no token (`home.server`, dm-group-chat-DESIGN.md section 4.5).
    public static let cloudSelfHost = "cloud-selfhost-v1"
    /// `page-credential`: the verified app gets a credential for its own page, which then gets
    /// the person's Cloud lease (`ws-cloud-conversations-v1`, cx-hnmbt.4).
    public static let pageCredential = "page-credential-v1"
    /// `page-credential {page}`: any trusted local connection gets a single-use credential bound
    /// to one page (its Origin only, never the Cloud lease); the Chief home's owner, whose app
    /// connection is not the verified app, hands the Channels page one.
    public static let scopedPageCredential = "page-credential-scoped-v1"
    /// `ws-listen`: a running owner opens its loopback page listener on request (cx-hnmbt.5); an older owner is handed off to the bundled build.
    public static let wsListen = "ws-listen-v1"
    /// `ws-listen {allow_origins}`: the listener admits every first-party page origin
    /// (cx-hnmbt.10); an owner without it gets the Channels origin only.
    public static let wsListenOrigins = "ws-listen-origins-v1"
    /// Groups placed among the loose personal workspaces: `top_index` on
    /// `list-personal` groups and on `workspace_group.update`, and a personal
    /// row for every new workspace (cmux-tui `personal_order.rs`).
    public static let personalMixedOrder = "personal-mixed-order-v1"
    /// `icon` on `workspace_group.update` and on personal groups.
    public static let workspaceGroupIcon = "workspace-group-icon-v1"
    /// `pinned` (saved) on `workspace_group.update` and on personal groups.
    public static let workspaceGroupPin = "workspace-group-pin-v1"
    /// `icon` on screen groups and saved screen groups, on
    /// `screen_group.update` and raw `update-screen-group` (null clears).
    public static let screenGroupIcon = "screen-group-icon-v1"
    /// `icon` on tab groups and saved tab groups, on `tab_group.update` and
    /// raw `update-tab-group` (null clears).
    public static let tabGroupIcon = "tab-group-icon-v1"
    /// `icon` on each session record of the home session registry
    /// (`list-personal`), set and cleared by raw `set-session-icon`: the
    /// icon the sidebar draws for that machine. Home daemon only.
    public static let sessionIcon = "session-icon-v1"
    /// `attachment` parts and their bytes on the local conversation owner:
    /// `conversation-attachment-upload` and `conversation-attachment-read`.
    public static let localAttachments = "local-attachments-v1"
    /// `link_preview` parts on the local conversation owner (a sender sends
    /// plain text to a daemon without it).
    public static let linkPreview = "link-preview-v1"
    /// `chief-inspect`: the Chief memory inspector's read-only API on the
    /// brain's daemon (advertised when the daemon knows the brain's tools socket).
    public static let chiefInspect = "chief-inspect-v1"
    public static var homeOnly: [String] { [profiles, personalTerminals, browserProfiles, bookmarks, localConversations, sessionIcon] }
    /// Written to the local daemon's personal rows instead of each machine's
    /// daemon once the local daemon serves `profiles-v1`.
    public static var personalOnHome: [String] { [workspaceGroups, savedTabGroups] }
    /// A replay taken inside an escape sequence carries the unfinished bytes
    /// in `pending` (main PR 15533). Without it, cmux-tui ends a view's attach
    /// stream whenever a PTY resize happens mid-sequence (a relaunch resizes
    /// every restored terminal), and the view freezes.
    public static let terminalPendingSequence = "terminal-pending-sequence-v1"
    /// Finished shell commands (OSC 133) stored as deletable rows with a
    /// retention once `set-terminal-command-history` turns it on; read with
    /// `list-terminal-commands`, deleted with `delete-terminal-commands`
    /// (plans/cmux-next/history.md 6).
    public static let terminalCommandHistory = "terminal-command-history-v1"
    /// `sidebar_layout.get|update` (plans/cmux-next/sidebar-sections.md 5;
    /// cmux-tui PR #16842).
    public static let sidebarLayout = "sidebar-layout-v1"
    /// The one sidebar document (`sidebar.get|move|pin|unpin|apply|adopt`,
    /// `sidebar_item`/`sidebar_section` on `session.events`;
    /// .cmux-scratch/sidebar-rewrite/CONTRACT.md). Without it the sidebar
    /// keeps the personal order and `sidebar-layout-v1` path.
    public static let sidebarDoc = "sidebar-doc-v1"
    /// The client orders rows from the sidebar document only, so the daemon
    /// sends no `workspace_placement` restatement (cmux-tui
    /// state/placement_shift.rs). Echoed only when this build orders rows
    /// from the document (`echoesPlacementShift`), never advertised alone.
    public static let placementShift = "placement-shift-v1"
    /// Set once at launch, before the first connection, by the App when this
    /// build has the sidebar document mirror (its rows come from the document,
    /// never from `workspace_placement`).
    public static var echoesPlacementShift: Bool {
        get { placementShiftEcho.withLock { $0 } }
        set { placementShiftEcho.withLock { $0 = newValue } }
    }
    private static let placementShiftEcho = OSAllocatedUnfairLock(initialState: false)
    /// `palette_usage.get|record|import`: the user's palette usage history
    /// and learned picks, owned by the daemon (plans/cmux-next/palette-ranking.md 5.3).
    public static let paletteUsage = "palette-usage-v1"
    /// `browser.devices.*` and `browser.tab.emulate*`: Chrome's device toolbar
    /// list and each browser tab's emulation (`extra.emulation`), owned by the daemon (cx-ocbf3).
    public static let browserDevices = "browser-devices-v1"
    /// `browser.tab.emulate {fit}`: Fit as 16:9 Desktop (cx-va1wd).
    public static let browserFit = "browser-fit-v1"
    /// `browser.tab.emulate {fit: "1280"}`: Fit as Desktop (1280) (cx-2ftlq).
    public static let browserFitWidth = "browser-fit-width-v1"
    /// keybindings.json owned by the daemon (`keybindings.*`, cx-9ce.17).
    public static let keybindings = "keybindings-v1"
    /// `put-blob`/`get-blob`: the owner's icon asset store, and `image:`/`svg:`
    /// icon values naming a stored asset on workspace, screen, room and profile icons.
    public static let iconAssets = "icon-assets-v1"
    /// `project.list|observe|add|update|remove|sync`: the device project list
    /// (plans/cmux-next/projects.md).
    public static let projectList = "project-list-v1"
    /// `move-tab-to-split` `respawn`: splitting a pane with its only tab
    /// spawns a new tab of the same kind in the source pane, in the same
    /// owner op (plans/cmux-next/layout-invariants.md).
    public static let tabSplitRespawn = "tab-split-respawn-v1"
    /// `move-tab-to-split` `keep_focus`: the new pane does not take focus (a
    /// pane the app opens for a subagent while the user types in the chat).
    public static let tabSplitKeepFocus = "tab-split-keep-focus-v1"
    /// `workspace.create` `focus`: a created workspace becomes the focused
    /// one only when asked (the app asks for the person's creations).
    public static let workspaceCreateFocus = "workspace-create-focus-v1"
    /// Additive shapes the app asks for through `set-client-info`: view
    /// identity on attach, creation receipts, caller-chosen creation attempt
    /// keys, and per-terminal color overrides.
    public static let attachIdentity = "attach-identity-v1"
    public static let creationReceipts = "creation-receipts-v1"
    public static let creationAttemptKeys = "creation-attempt-keys-v1"
    public static let terminalColorOverrides = "terminal-color-overrides-v1"
    /// Snapshot attach with scrollback: READY snapshots followed by their
    /// history as raw-DEFLATE `snapshot {phase: "history"}` chunks
    /// (`TerminalAttachment`; plans/cmux-next/ghostty-next.md 2.2).
    public static let terminalSnapshotHistory = "terminal-snapshot-history-v1"
    /// A READY cut exactly at a host resize, restored with the view's own
    /// reflowed history (S2c; plans/cmux-next/ghostty-next.md 2.2).
    public static let terminalSnapshotLocalHistory = "terminal-snapshot-local-history-v1"
    /// The Kitty image replay after a plain READY (S3k).
    public static let terminalSnapshotImages = "terminal-snapshot-images-v1"
    /// The OSC 52 clipboard-read broker: `terminal-clipboard-subscribe`,
    /// `terminal-clipboard-reply` and the targeted read events
    /// (`TerminalClipboardBroker`; plans/cmux-next/ghostty-config.md).
    public static let terminalClipboardRead = "terminal-clipboard-read-v1"
    /// The page relay's origin claim (`ResourceRelay.originClaimCapability`,
    /// `ClientHello.originClaimCapability`).
    public static let originClaim = "origin-claim-v1"
    /// Page ids on page relays and the per-page allow list (`page-router-v1`;
    /// `DaemonClientRole.pageRouterCapability`).
    public static let pageRouter = "page-router-v1"
    /// `read-session-journal` for agent history (`AgentHistory`).
    public static let sessionJournal = "session-journal-v1"
    /// Per-terminal resource usage (`TerminalResourcesRequest.capability`).
    public static let terminalResources = "terminal-resources-v1"
    /// Owner machine metadata on `identify` (`HandshakeLines`).
    public static let machineIdentity = "machine-identity-v1"
    /// Registered `agent_cli` app providers (`AppProviderSession`).
    public static let agentCLIAppProvider = "agent-cli-app-provider-v1"
    /// Agent inventory invalidation events for app providers (`AppProviderSession`).
    public static let agentCLIAppInvalidation = "agent-cli-app-invalidation-v1"
    /// Admission receipts on the agent inventory watch (`DaemonReadyConnection`).
    public static let agentInventoryWatchAdmission = "agent-inventory-watch-admission-v1"
    /// Stash, a native OneTab (`stash.*`; `StateResourceClient+Stash.swift`).
    public static let stash = "stash-v1"
    /// Whole workspaces in a stash: `stash.create {workspaces}` closes them with their terminals
    /// (`StateResourceClient.stashWorkspaces`), and their members list with `kind: "workspace"`.
    public static let stashWorkspaces = "stash-workspaces-v1"
    /// `layout.bulk` close: one gesture over several panes, screens or workspaces is one commit and
    /// one closed-history group, so one Reopen Closed brings all of them back
    /// (`StateResourceClient.closeBulk`).
    public static let layoutBulk = "layout-bulk-v1"

    /// Capabilities the bundled daemon must serve. The bundled cmux-tui is
    /// built from this checkout's own cmux-tui tree
    /// (scripts/cmux-next/pin-cmux-tui.sh), and
    /// scripts/cmux-next/check-daemon-capabilities.sh fails the build when it
    /// does not serve one of these or `required`. The GUI still checks each
    /// with `DaemonIdentity.supports`, for remote and older daemons.
    public static var optional: [String] { [workspaceGroups, workspaceMetadata, workspaceNameSource, tabMetadata, frontendBrowserTabs, tabDrag,
                                            notificationAck, tabGroups, savedTabGroups, terminalEnv, terminalPlacementEnv,
                                            terminalReap, resumeCommand, terminalReaperActive, batchClose, layoutBulk, closeReason, closeWorkspaceIfEmpty, browserHostProvider, frontendBrowserActivate, frontendBrowserInsertAfter, frontendBrowserTabKeys, loopbackForward, browserRuntime, screenMetadata, screenGroups, profiles, personalRemoteLocalhost,
                                            terminalPendingSequence, personalTerminals, browserProfiles, notificationSource,
                                            terminalShellArgs, terminalFrontendShellIntegration, launchSnapshot, bookmarks, bookmarkIcon, history, workspacePin, workspaceChecklist, notificationMarkUnread, tabMarkUnread, workspaceDescription, workspaceStatus,
                                            terminalCommandHistory, dockColumns, edgeDocks, dockColumnRole, pinnedDock, pinnedDockAlone, rows, columnMove, tabColumnRespawn, endTerminalsKeepLayout, stateResources,
                                            sessionIdentity, localConversations, conversationDraftEvents, chiefLive, cloudChiefLive, conversationRuns, cloudConversationRuns, cloudConversationTyping, tabSplitRespawn, tabSplitKeepFocus, workspaceCreateFocus, frontendBrowserHistory, frontendBrowserTabProfile,
                                            attachIdentity, creationReceipts, creationAttemptKeys, terminalColorOverrides,
                                            workspaceKind, workspaceAgentFolder, workspaceAgentStart, conversationTabs, agentSessionTabs, agentSessionAttach, agentSessionObserve, agentSessionStart, agentSessionStartKeyedReason, agentSessionTrust, agentSessionAdopt, agentSessionChildren, pageTabs, pageTabRoute, windowRecords, appScreens, conversationSearch, conversationThreads, conversationThread, conversationInboxState, homeInbox, chiefEvents, cloudConversations, cloudHostReplica, cloudAttachments, cloudSelfHost, pageCredential, scopedPageCredential, wsListen, wsListenOrigins, localAttachments,
                                            tabWorkspaceName, terminalSnapshotHistory, terminalSnapshotLocalHistory, terminalSnapshotImages,
                                            terminalClipboardRead, personalMixedOrder, sidebarLayout, sidebarDoc, placementShift, paletteUsage, browserDevices, browserFit, browserFitWidth, projectList, splitClientKeys, splitClientSplitID, conversationTabSplit, terminalInputWhileCreating,
                                            workspaceGroupIcon, workspaceGroupPin, screenGroupIcon, tabGroupIcon, sessionIcon, chiefInspect, feedLocalOwner, remoteTerminalTabs, detachedTerminals, tabRestart, tabRestartKeptLayout, tabPark,
                                            originClaim, pageRouter, sessionJournal, terminalResources, keybindings, iconAssets, linkPreview, sharedSizing,
                                            machineIdentity, agentCLIAppProvider, agentCLIAppInvalidation, agentInventoryWatchAdmission, sendExpectForeground, stash, stashWorkspaces] }

    /// App code waiting for a daemon half that no branch has yet. Each
    /// feature shows disabled with its reason (or refuses with it) while the
    /// bundled daemon lacks the capability. The list only shrinks
    /// (DaemonCapabilityExportTests): new app features land with their
    /// daemon half, and check-daemon-capabilities.sh fails once the bundled
    /// daemon serves an entry, so it moves to `optional`.
    public static var unservedByBundledDaemon: [String] { [] }

    /// Whether the bundled daemon (this tree's cmux-tui) serves `capability`:
    /// a daemon without it is an older build, and restarting cmux updates it.
    public static func isServedByBundledDaemon(_ capability: String) -> Bool {
        required.contains(capability) || optional.contains(capability)
    }

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    /// `terminalFrontendShellIntegration` is not in it: only a connection
    /// that resolves the integration echoes it (`handshakeCapabilities`).
    /// `sharedSizing` is not either: a terminal attachment that names its device adds it
    /// (`TerminalAttachment.attach(device:)`); other connections only read it from `identify`.
    public static var advertised: [String] {
        // `placementShift` only with the sidebar document (`handshakeCapabilities`).
        (required + optional + unservedByBundledDaemon).filter { $0 != terminalFrontendShellIntegration && $0 != placementShift && $0 != sharedSizing }
    }

    /// What a connection echoes in `set-client-info`.
    public static func handshakeCapabilities(_ advertised: [String], resolvesShellIntegration: Bool) -> [String] {
        // The document path echoes `placement-shift-v1` together with `sidebar-doc-v1`.
        let document = Self.echoesPlacementShift && advertised.contains(sidebarDoc) ? [placementShift] : []
        return (resolvesShellIntegration ? advertised + [terminalFrontendShellIntegration] : advertised) + document
    }
}
