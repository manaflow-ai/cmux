public import CmuxNextWakeups
import Foundation
public import Observation
import os

public enum DaemonConnectionState: Sendable, Equatable {
    case connecting
    case connected(DaemonIdentity)
    case disconnected(String)
    case failed(String)
}

/// The app's read-only mirror of the daemon tree (plans/cmux-next/architecture.md
/// sections 1-2). Records are fine-grained @Observable classes with stable
/// identity, patched in place from deltas; views observe the smallest record
/// they render. Events arrive decoded off the main actor and are applied in
/// batches at most once per frame (`run(connection:scheduler:)`).
@Observable @MainActor
public final class DaemonStore: StateResourceQueries {
    public internal(set) var workspaces: [WorkspaceModel] = [] { didSet { adoptUnread() } }
    public internal(set) var groups: [WorkspaceGroupModel] = []
    /// Tabs the unread count read, one by one (tests: an observer of the badge reads no tab).
    @ObservationIgnored public internal(set) var unreadTabReads = 0
    /// The unread counts of all workspaces (``UnreadTotals``), summed from each workspace's own
    /// count when one changes and assigned only when the sum changes: an observer of the badge
    /// observes this one value, never the tabs.
    public internal(set) var unreadTotals = UnreadTotals()
    /// Rooms in order (`profiles-v1`, home session only; the wire calls
    /// them profiles). Empty on a daemon without personal state.
    public internal(set) var profiles: [ProfileModel] = []
    /// The rest of the home session's personal state (`PersonalStore`).
    public internal(set) var personal = PersonalStore()
    public internal(set) var savedTabGroups: [SavedTabGroupModel] = []
    /// The open groups of `savedTabGroups` (`TabGroupModel.isSaved`).
    @ObservationIgnored var savedOpenGroups: Set<TabGroupID> = []
    /// Sidebar flattening, recomputed only when order, membership, or groups change.
    public internal(set) var sidebarSections: [SidebarSection] = []
    public internal(set) var connectionState: DaemonConnectionState = .connecting { didSet { dropGrace.note(oldValue, connectionState) } }
    public let dropGrace = DaemonDropGrace()
    /// Counts connection changes (connected, disconnected, shut down), so a
    /// reader can tell facts seen on an earlier connection from this one
    /// even when it missed the states in between.
    @ObservationIgnored public internal(set) var connectionEpoch = 0
    /// The identity of the last daemon that completed a handshake. Kept
    /// through a disconnect; replaced on every (re)connect, whose daemon may
    /// be a different generation or build with different capabilities.
    public internal(set) var identity: DaemonIdentity?
    public internal(set) var generation: DaemonGeneration?
    public internal(set) var registryID: String?
    public internal(set) var workspaceRevision: UInt64 = 0
    /// Bumped once per apply (batch, snapshot, intent) that changed which
    /// tabs the tree lists, their panes or their order: one read for an
    /// observer that follows every tab list, instead of a walk of every pane.
    public private(set) var tabListRevision: UInt64 = 0
    public let session = SessionStateStore()
    /// Recent notifications, newest last (bounded).
    public internal(set) var notifications: [DaemonNotification] = []
    /// What the sidebar shows of a tab's unread notification
    /// (`notificationText(for:)`): each live notification's text by id, and
    /// the ledger's newest unread text by surface, seeded at connect.
    var notificationTexts: [NotificationID: String] = [:]
    var ledgerNotificationTexts: [SurfaceID: String] = [:]
    /// True once the first snapshot is applied.
    public internal(set) var isLoaded = false
    /// True while the tree is the daemon's launch snapshot (drawn before
    /// connecting) and no live snapshot has replaced it yet.
    public internal(set) var isProvisional = false
    /// The highest event sequence the tree reflects: advanced after a batch
    /// applies without needing a resync. A snapshot can cover consumed tree events,
    /// but cannot acknowledge session events still waiting in the inbox or pump. Readers compare it with
    /// `DaemonConnection.eventSequence()` taken after a write (read-your-writes
    /// without refetching the tree).
    public internal(set) var appliedSequence: UInt64 = 0
    /// Client transaction ids the daemon echoed, newest last (bounded).
    public internal(set) var confirmedTransactions: [ClientTransactionID] = []
    /// Called once per echoed transaction id, on the main actor.
    @ObservationIgnored public var onTransactionConfirmed: ((ClientTransactionID) -> Void)?
    /// `whenApplied` callbacks waiting for their transaction's echo.
    @ObservationIgnored var appliedWaiters: [AppliedWaiter] = []
    /// A disconnect was applied: every waiter runs at the next flush.
    @ObservationIgnored var drainAppliedWaiters = false
    struct AppliedWaiter {
        var transaction: ClientTransactionID
        var sequence: UInt64?
        var body: @MainActor () -> Void
    }
    /// Called on the main actor, synchronously, once the set of loaded
    /// workspaces changed (one joined or left, or a provisional one was
    /// confirmed): right after the event batch, snapshot, or intent that
    /// changed it, before any observer or frame runs. The App keeps window
    /// membership in step here, so a window never shows after its last
    /// workspace is gone. A move, a group change or a change to one
    /// workspace keeps the set and never calls it: the App's membership pass
    /// visits every workspace, and the sidebar churn ran it per change.
    @ObservationIgnored public var onWorkspaceListChanged: (() -> Void)?
    /// Runs when the connection drops or the daemon shuts down (before any reconnect).
    @ObservationIgnored public var onDisconnected: (@MainActor () -> Void)?
    /// Bookmark and conversation events (not in the tree snapshot), on the main actor.
    @ObservationIgnored public let sideEvents = DaemonSideEvents()
    /// The workspace set (`listID`s) last reported to `onWorkspaceListChanged`.
    @ObservationIgnored var notifiedWorkspaceList: Set<String>?
    /// Bumped by every sidebar flattening (`recomputeSidebar`, which every
    /// structural change runs): while it stays, the workspace set is the one
    /// last checked, so `workspaceListMayHaveChanged` skips its O(n) set
    /// build (status ticks apply batches several hundred times a second).
    @ObservationIgnored var listGeneration: UInt64 = 0
    @ObservationIgnored var checkedListGeneration: UInt64?
    /// Nesting of batch applies; the hook runs when the outermost ends.
    @ObservationIgnored var applyDepth = 0
    @ObservationIgnored let updateCycles = UpdateCycleDetector(owner: "DaemonStore.apply")
    @ObservationIgnored public var transactionLimit = 64
    @ObservationIgnored public var notificationLimit = 200

    /// O(1) lookups kept in step with the records (StoreIndex.swift).
    @ObservationIgnored var index = StoreIndex()
    var tabsBySurface: [SurfaceID: TabModel] { index.tabsBySurface }
    var panesByHandle: [PaneID: PaneModel] { index.panesByHandle }
    var screensByHandle: [ScreenID: ScreenModel] { index.screensByHandle }
    var workspacesByKey: [WorkspaceKey: WorkspaceModel] { index.workspacesByKey }
    var tabGroupsByID: [TabGroupID: TabGroupModel] { index.tabGroupsByID }
    @ObservationIgnored public internal(set) var agents = AgentRoster()
    /// Presence that arrived before its tab was indexed (an agent hook right after its terminal is
    /// created, a restored session, a hook replayed on reconnect). No snapshot carries presence, so
    /// the tab takes it from here when it is indexed (`prime`). Live-only like the tabs': a clear
    /// drops it (`clearPresence`), and it holds at most ``heldPresenceLimit`` surfaces.
    @ObservationIgnored var heldPresence: [SurfaceID: AgentPresence] = [:]
    /// The most surfaces whose presence is held for a tab not indexed yet.
    static let heldPresenceLimit = 256
    var heldPresenceCount: Int { heldPresence.count }
    @ObservationIgnored var directories = TerminalDirectories()
    /// Pending typed intents shown on top of the confirmed mirror
    /// (DaemonStore+Intents.swift).
    @ObservationIgnored var intentLog = IntentLog()
    /// The open script-batch stage, if any (DaemonStore+Stage.swift).
    @ObservationIgnored var stage: StoreStage?
    /// Read-your-writes waits by sequence, counted (``beginAppliedWait(_:)``): a stage holds no event
    /// one of them needs.
    @ObservationIgnored var sequenceWaits: [UInt64: Int] = [:]
    /// The one model of each pending split's provisional pane, by public pane id: every overlay
    /// restore shows it, and the daemon's pane takes it over in place (`confirmedPane`).
    @ObservationIgnored var provisionalPanes: [String: PaneModel] = [:]
    /// Stand-in pane handles a pending create names as its target (a New Column or split pressed on
    /// a create still in flight, a Ctrl-` on Cmd-N's pane), by handle: what made the stand-in, by
    /// which the daemon's pane that takes it over is found (``daemonHandle(showing:)``).
    @ObservationIgnored var standInTargets: [PaneID: StandInOrigin] = [:]
    /// Creates waiting for the daemon's pane of a stand-in whose own create is in flight
    /// (``daemonTarget(_:)``), resumed by the reconcile that resolves them.
    @ObservationIgnored var standInWaits: [StandInWait] = []
    /// True while daemon state applies to the confirmed records (the
    /// intent overlay is undone).
    @ObservationIgnored var overlayLifted = false
    /// The overlay moved a workspace or changed its group since the last
    /// sidebar flattening.
    @ObservationIgnored var sidebarNeedsRecompute = false
    /// Called once per intent when it leaves the log (main actor), after the visible state is complete again.
    @ObservationIgnored public var onIntentSettled: ((ClientTransactionID, IntentSettlement) -> Void)?
    /// Settlements of the current lift, reported when it ends.
    @ObservationIgnored var intentSettlements: [(ClientTransactionID, IntentSettlement)] = []
    /// Mirror single-writer violations found by the debug-build check (DaemonStore+MirrorCheck.swift), newest last (bounded).
    @ObservationIgnored public internal(set) var mirrorViolations: [String] = []
    /// Called on the main actor for each new mirror violation.
    @ObservationIgnored public var onMirrorViolation: ((String) -> Void)?
    /// A create intent's tab arrived with its transaction echo: (provisional tab id, created tab).
    @ObservationIgnored public var onTabCreated: ((String, TabModel) -> Void)?
    /// Same, for a page tab's create intent (`page-tabs-v1`); agent tabs own `onTabCreated`.
    @ObservationIgnored public var onPageTabCreated: ((String, TabModel) -> Void)?
    /// The layout as the last allowed writer left it (debug builds).
    @ObservationIgnored var mirrorFingerprint: Int?
    @ObservationIgnored var mirrorFingerprintTakenAt: ContinuousClock.Instant?
    /// Events at or below this sequence are superseded by the last snapshot.
    @ObservationIgnored var snapshotBarrier: UInt64 = 0
    /// The last live snapshot per workspace and what changed since (``SnapshotMemo``): the next
    /// snapshot applies only the workspaces that differ.
    @ObservationIgnored var snapshotMemo = SnapshotMemo()
    /// Workspace snapshots the main actor compared or keyed for ``snapshotMemo`` since creation
    /// (tests: a live resync with its off-main ``SnapshotDiff`` walks none).
    @ObservationIgnored var snapshotWorkspacesWalkedOnMain = 0
    /// Set while `run(connection:scheduler:)` drives the store.
    @ObservationIgnored var driver: StoreDriver?
    /// Test seam (nil in the app): while it returns true for the buffered events, `drain` leaves them
    /// buffered and asks for no frame, as a daemon whose events arrive late; ``releaseHeldEvents()``
    /// applies them. A test holds one report this way to order it after an app step deterministically.
    @ObservationIgnored public var eventHold: (@MainActor ([DaemonEventEnvelope]) -> Bool)?
    @ObservationIgnored var isResyncing = false
    /// The `list-personal` refetch a `personal-changed` asks for (`refetchPersonal`).
    @ObservationIgnored var personalRefetch = PersonalRefetch()
    /// `refresh()` callers waiting for a snapshot requested after their call.
    @ObservationIgnored var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    /// Spacing and budget of failed-snapshot retries; reset by the next applied one.
    @ObservationIgnored var resyncPacer = RetryPacer(.resync)
    /// The pending retry of a failed snapshot (cancelled when the driver ends).
    @ObservationIgnored var resyncRetry: DemandTimer?
    /// The retry budget ran out: the next daemon event resyncs.
    @ObservationIgnored var needsResync = false
    /// Clock of the retry spacing (tests inject one that does not wait).
    @ObservationIgnored public var resyncClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.store")

    /// Tab ids of the first snapshot of the current connection: tabs the
    /// connection found already there (page history skips their reload).
    @ObservationIgnored public private(set) var restoredTabIDs: Set<String> = []
    @ObservationIgnored var restoredEpoch: Int?
    /// The connection epoch of the last live snapshot applied: it changes once
    /// per connection, when that connection's first tree lands. Observers that
    /// must look at every workspace once per connection key off it.
    public internal(set) var liveTreeEpoch: Int?
    /// Bumped each time the set of loaded workspaces changes (one joined or
    /// left, or a provisional one was confirmed), never for a move or a
    /// change to one workspace: observers that track membership read it
    /// instead of `workspaces`, whose order every move changes.
    public internal(set) var workspaceSetRevision: UInt64 = 0

    public init() {}

    // MARK: Lookup (O(1))

    public func workspace(key: WorkspaceKey) -> WorkspaceModel? { index.workspacesByKey[key] }
    public func workspace(handle: WorkspaceHandle) -> WorkspaceModel? { index.workspacesByHandle[handle] }
    public func screen(_ handle: ScreenID) -> ScreenModel? { index.screensByHandle[handle] }
    public func pane(_ handle: PaneID) -> PaneModel? { index.panesByHandle[handle] }
    public func tab(surface: SurfaceID) -> TabModel? { index.tabsBySurface[surface] }
    /// The current tab records, invalidated only when the tab/pane topology
    /// changes. Callers that need to inspect every tab without observing row
    /// status should use this instead of walking ``workspaces``.
    public var liveTabs: [TabModel] {
        _ = tabListRevision
        return Array(index.tabsByID.values)
    }
    /// The shell's reported folder (OSC 7); a remote terminal's is never a local cwd.
    public func noteTerminalDirectory(_ directory: String?, surface: SurfaceID) {
        guard let tab = index.tabsBySurface[surface], tab.kind != .remoteTerminal else { return }
        tab.setObservedCwd(directories.note(directory, surface: surface))
    }
    // The lookups below read `tabListRevision` first, so a tracked caller (a wait for a tab
    // to appear or move) hears the tab list change; `tab(surface:)` (hot paths) does not
    // (a wait by surface reads `tabListRevision` itself, as AppServices.locateTab does).
    public func tab(terminal: TerminalID) -> TabModel? {
        _ = tabListRevision
        return index.tabsByTerminal[terminal]
    }
    /// The tab of a public terminal id (`term_…`, `CMUX_TUI_TERMINAL_ID`).
    public func tab(terminalResource id: ResourceID) -> TabModel? {
        _ = tabListRevision
        return index.tabsByTerminalResource[id]
    }
    /// The tab with durable id `id` (`TabModel.id`).
    public func tab(id: String) -> TabModel? {
        _ = tabListRevision
        return index.tabsByID[id]
    }
    /// The tab with durable id or tab resource id `id` (a tab first seen
    /// without a `tab_` resource id keeps its first id; links name it by
    /// the resource id).
    public func tab(idOrResource id: String) -> TabModel? {
        _ = tabListRevision
        return index.tabsByID[id] ?? index.tabsByResource[ResourceID(rawValue: id)]
    }
    public func tabGroup(_ id: TabGroupID) -> TabGroupModel? { index.tabGroupsByID[id] }
    public func group(_ id: WorkspaceGroupID) -> WorkspaceGroupModel? { groups.first { $0.id == id } }
    public func profile(_ id: ProfileID) -> ProfileModel? { profiles.first { $0.id == id } }

    /// The workspace whose screens hold pane `handle`. It reads
    /// `workspaces` first, so a tracked caller still hears a workspace come or go.
    public func workspace(containing handle: PaneID) -> WorkspaceModel? {
        _ = workspaces
        return index.panesByHandle[handle].flatMap(index.screen(holding:)).flatMap(index.workspace(holding:))
    }

    /// The screen holding pane `handle`.
    public func screen(containing handle: PaneID) -> ScreenModel? {
        index.panesByHandle[handle].flatMap(index.screen(holding:))
    }

    /// The pane currently holding `surface`.
    public func pane(containing surface: SurfaceID) -> PaneModel? {
        _ = tabListRevision
        return index.tabsBySurface[surface].flatMap(index.pane(holding:))
    }

    /// The pane holding `tab` (by identity).
    public func pane(holding tab: TabModel) -> PaneModel? {
        _ = tabListRevision
        return index.pane(holding: tab)
    }

    // MARK: Snapshot

    /// Replaces the confirmed tree, reusing records by durable identity,
    /// then shows the pending intents on it again.
    public func apply(snapshot tree: DaemonTree) {
        apply(snapshot: tree, diff: nil)
    }

    /// ``apply(snapshot:)`` with the workspaces that differ from the last applied snapshot already
    /// found (``SnapshotDiff``, computed off the main thread by the resync); nil or a diff of an
    /// older memo compares here. Only the changed, new and removed workspaces, and those an event
    /// touched since, are applied, indexed and laid; a snapshot the memo cannot vouch for
    /// (``incrementalDiff(_:diff:)``) applies in full.
    func apply(snapshot tree: DaemonTree, diff: SnapshotDiff?) {
        // A snapshot holds everything the daemon did: a staged batch shows first (every joined batch's
        // part), then the snapshot.
        stage?.commitAll()
        withOverlayLifted(snapshot: true) {
            if let diff = incrementalDiff(tree, diff: diff) {
                applyTreeIncrementally(tree, touching: touchedWorkspaces(diff))
                advanceSnapshotMemo(tree, applying: diff)
            } else {
                applyTree(tree)
                rebuildIndex()
                recordSnapshotMemo(tree)
            }
            if isProvisional { isProvisional = false }
            if !isLoaded {
                isLoaded = true
                DaemonLaunchTimings.shared.mark("daemon.first_tree_applied")
            }
            if liveTreeEpoch != connectionEpoch { liveTreeEpoch = connectionEpoch }
            if restoredEpoch != connectionEpoch {
                restoredEpoch = connectionEpoch
                restoredTabIDs = currentTabIDs
            }
            ProvisionalSplit.noteDaemonPanes(in: self)
        }
        workspaceListMayHaveChanged()
        runAppliedWaiters(nil, snapshot: true)
    }

    /// The tree a snapshot applied up to `barrier` holds every personal change at or below it; a
    /// later one is fetched now.
    func snapshotCoveredPersonal(through barrier: UInt64) {
        personalRefetch.covered(through: barrier)
        if personalRefetch.pending != nil { refetchPersonal() }
    }

    /// Shows the daemon's launch snapshot (`LaunchSnapshot`) before the
    /// first connection: the same models as a live snapshot, reused by
    /// durable identity when the live one arrives (so nothing is rebuilt
    /// when the layout did not change), but `isLoaded` stays false, so
    /// nothing that waits for the live tree (window restore, membership,
    /// workspace-list hooks) runs from it. Ignored once a live snapshot
    /// applied.
    public func applyProvisional(snapshot tree: DaemonTree) {
        guard !isLoaded else { return }
        withOverlayLifted {
            applyTree(tree)
            // A launch snapshot is not the live tree: the first live one applies in full.
            snapshotMemo.reset()
            isProvisional = true
            // Launch snapshot tabs are restored tabs (pages made from them reload).
            restoredTabIDs = currentTabIDs
            rebuildIndex()
        }
    }

    private var currentTabIDs: Set<String> {
        Set(workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
    }

    private func applyTree(_ tree: DaemonTree) {
        directories.follow(tree.generation)
        if let value = tree.generation, generation != value { generation = value }
        if let value = tree.registryID, registryID != value { registryID = value }
        if workspaceRevision != tree.workspaceRevision { workspaceRevision = tree.workspaceRevision }
        if let reordered = reconcile(groups, with: tree.groups, id: \.id, make: WorkspaceGroupModel.init, update: { $0.update($1) }) {
            groups = reordered
        }
        applyPersonal(tree.personal)
        if let reordered = reconcile(savedTabGroups, with: tree.savedTabGroups, id: \.id, make: SavedTabGroupModel.init,
                                     update: { $0.update($1) }) {
            savedTabGroups = reordered
        }
        savedOpenGroups = Set(savedTabGroups.compactMap(\.openGroup))
        if let reordered = reconcile(workspaces, with: tree.workspaces, id: WorkspaceModel.identity, make: confirmedWorkspace,
                                     update: { $0.update($1) }) {
            workspaces = reordered
        }
    }

    /// Seeds agent state (`list-agents`), e.g. after connect.
    public func apply(agents: [AgentStatus]) {
        self.agents.seed(agents)
        for (surface, tab) in tabsBySurface { tab.setAgent(self.agents.bySurface[surface]) }
    }

    /// Records a completed handshake before its `.connected` event drains, so capability checks right after connect see this daemon.
    public func noteHandshake(_ identity: DaemonIdentity) {
        if self.identity != identity { self.identity = identity }
    }

    /// Marks the connection failed: no retry can fix it, or it outlived the startup deadline (`DaemonStartupState.showsFailure`).
    public func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    /// A remote machine's reconnect spent its timed retries and waits for an event only
    /// (`DaemonConnection.observeRetriesSpent`): its header reads offline, not connecting (HQ
    /// #4877 G4). Cleared by the next connect and by a new attempt.
    public private(set) var retriesSpent = false

    public func noteRetriesSpent(_ spent: Bool) {
        if spent, case .connected = connectionState { return }
        if retriesSpent != spent { retriesSpent = spent }
    }

    // MARK: Derived state

    /// Indexes the whole tree again, primes every record and flattens the
    /// sidebar: a snapshot only. Events change the index per record
    /// (`indexed(_:)`), and the sidebar once per batch (`sidebarNeedsRecompute`).
    func rebuildIndex() {
        index.rebuild(workspaces)
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes { prime(pane) }
            }
        }
        recomputeSidebar()
        session.overlay(workspaces)
    }

    /// (Re)indexes `workspace` and its subtree and lays the state over it.
    func indexed(_ workspace: WorkspaceModel) {
        index.insert(workspace)
        for screen in workspace.screens {
            for pane in screen.panes { prime(pane) }
        }
        session.overlay([workspace])
    }

    /// (Re)indexes `screen` in `workspace` and lays the state over it and
    /// over the workspace (its screen groups follow the screen order).
    func indexed(_ screen: ScreenModel, in workspace: WorkspaceModel) {
        index.insert(screen, in: workspace)
        for pane in screen.panes { prime(pane) }
        session.lay(screen: screen)
        session.lay(workspaceOnly: workspace)
    }

    /// (Re)indexes `pane` in `screen` and lays the state over its tabs.
    func indexed(_ pane: PaneModel, in screen: ScreenModel) {
        index.insert(pane, in: screen)
        prime(pane)
        for tab in pane.tabs { SessionStateStore.lay(session.mirror, over: tab) }
    }

    /// (Re)indexes `tab` in `pane` and lays the state over it.
    func indexed(_ tab: TabModel, in pane: PaneModel) {
        index.insert(tab, in: pane)
        prime(tab)
        SessionStateStore.lay(session.mirror, over: tab)
    }

    /// What a pane's records learn when they are indexed: each group whether
    /// it is a saved group's open one, each tab its agent and folder.
    private func prime(_ pane: PaneModel) {
        for group in pane.tabGroups {
            let saved = savedOpenGroups.contains(group.id)
            if group.isSaved != saved { group.isSaved = saved }
        }
        for tab in pane.tabs { prime(tab) }
    }

    /// What a tab learns when it is indexed: its agent and its observed folder.
    private func prime(_ tab: TabModel) {
        if tab.agent == nil, let agent = agents.bySurface[tab.surface] { tab.setAgent(agent) }
        if let presence = heldPresence.removeValue(forKey: tab.surface) { tab.setPresence(presence) }
        tab.setObservedCwd(directories.directory(for: tab.surface))
    }

    /// Publishes a tab list change once the visible state is complete.
    func publishTabListChange() {
        if index.takeTabListChange() { tabListRevision &+= 1 }
    }

    /// Runs `onWorkspaceListChanged` when the workspace set differs from
    /// the last one reported (outside a batch, once loaded). Order is not
    /// membership: a move or a group change leaves the set as it was.
    func workspaceListMayHaveChanged() {
        // Tracked without a hook too: a hook installed later runs for the next change, not for
        // a set its installer (`reconcileMembership`) has just read.
        guard applyDepth == 0, isLoaded else { return }
        guard checkedListGeneration != listGeneration else { return }
        checkedListGeneration = listGeneration
        if let notified = notifiedWorkspaceList, notified.count == workspaces.count,
           workspaces.allSatisfy({ notified.contains($0.listID) }) { return }
        let list = Set(workspaces.map(\.listID))
        guard list != notifiedWorkspaceList else { return }
        notifiedWorkspaceList = list
        workspaceSetRevision &+= 1
        onWorkspaceListChanged?()
    }

    func recomputeSidebar() {
        listGeneration &+= 1
        let ungrouped = workspaces.filter { workspace in workspace.group.map { id in !groups.contains { $0.id == id } } ?? true }
        var sections = [SidebarSection(group: nil, workspaces: ungrouped)]
        for group in groups.sorted(by: { $0.index < $1.index }) {
            sections.append(SidebarSection(group: group, workspaces: workspaces.filter { $0.group == group.id }))
        }
        let unchanged = sections.count == sidebarSections.count && zip(sections, sidebarSections).allSatisfy { new, old in
            new.group === old.group && new.workspaces.count == old.workspaces.count
                && zip(new.workspaces, old.workspaces).allSatisfy { $0 === $1 }
        }
        if !unchanged { sidebarSections = sections }
    }
}
