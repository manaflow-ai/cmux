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
    public internal(set) var workspaces: [WorkspaceModel] = []
    public internal(set) var groups: [WorkspaceGroupModel] = []
    /// Rooms in order (`profiles-v1`, home session only; the wire calls
    /// them profiles). Empty on a daemon without personal state.
    public internal(set) var profiles: [ProfileModel] = []
    /// The rest of the home session's personal state (`PersonalStore`).
    public internal(set) var personal = PersonalStore()
    public internal(set) var savedTabGroups: [SavedTabGroupModel] = []
    /// Sidebar flattening, recomputed only when order, membership, or groups change.
    public internal(set) var sidebarSections: [SidebarSection] = []
    public internal(set) var connectionState: DaemonConnectionState = .connecting
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
    public let session = SessionStateStore()
    /// Recent notifications, newest last (bounded).
    public internal(set) var notifications: [DaemonNotification] = []
    /// True once the first snapshot is applied.
    public internal(set) var isLoaded = false
    /// True while the tree is the daemon's launch snapshot (drawn before
    /// connecting) and no live snapshot has replaced it yet.
    public internal(set) var isProvisional = false
    /// The highest event sequence the tree reflects: advanced after a batch
    /// applies without needing a resync, and to a snapshot's barrier once
    /// that snapshot is applied. Readers compare it with
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
    /// Called on the main actor, synchronously, once the loaded workspace
    /// list (membership or sidebar order) changed: right after the event
    /// batch, snapshot, or intent that changed it, before any
    /// observer or frame runs. The App keeps window membership in step here,
    /// so a window never shows after its last workspace is gone.
    @ObservationIgnored public var onWorkspaceListChanged: (() -> Void)?
    /// Runs when the connection drops or the daemon shuts down (before any reconnect).
    @ObservationIgnored public var onDisconnected: (@MainActor () -> Void)?
    /// Bookmark and conversation events (not in the tree snapshot), on the main actor.
    @ObservationIgnored public let sideEvents = DaemonSideEvents()
    /// The list last reported to `onWorkspaceListChanged`.
    @ObservationIgnored var notifiedWorkspaceList: [String]?
    /// Nesting of batch applies; the hook runs when the outermost ends.
    @ObservationIgnored var applyDepth = 0
    @ObservationIgnored let updateCycles = UpdateCycleDetector(owner: "DaemonStore.apply")
    @ObservationIgnored public var transactionLimit = 64
    @ObservationIgnored public var notificationLimit = 200

    @ObservationIgnored var tabsBySurface: [SurfaceID: TabModel] = [:]
    @ObservationIgnored var panesByHandle: [PaneID: PaneModel] = [:]
    @ObservationIgnored var screensByHandle: [ScreenID: ScreenModel] = [:]
    @ObservationIgnored var workspacesByHandle: [WorkspaceHandle: WorkspaceModel] = [:]
    @ObservationIgnored var workspacesByKey: [WorkspaceKey: WorkspaceModel] = [:]
    @ObservationIgnored var tabGroupsByID: [TabGroupID: TabGroupModel] = [:]
    @ObservationIgnored var agentsBySurface: [SurfaceID: AgentStatus] = [:]
    @ObservationIgnored var directories = TerminalDirectories()
    /// Pending typed intents shown on top of the confirmed mirror
    /// (DaemonStore+Intents.swift).
    @ObservationIgnored var intentLog = IntentLog()
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
    /// Events at or below this sequence are superseded by the last snapshot.
    @ObservationIgnored var snapshotBarrier: UInt64 = 0
    /// Set while `run(connection:scheduler:)` drives the store.
    @ObservationIgnored var driver: StoreDriver?
    @ObservationIgnored var isResyncing = false
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

    public init() {}

    // MARK: Lookup (O(1))

    public func workspace(key: WorkspaceKey) -> WorkspaceModel? { workspacesByKey[key] }
    public func workspace(handle: WorkspaceHandle) -> WorkspaceModel? { workspacesByHandle[handle] }
    public func screen(_ handle: ScreenID) -> ScreenModel? { screensByHandle[handle] }
    public func pane(_ handle: PaneID) -> PaneModel? { panesByHandle[handle] }
    public func tab(surface: SurfaceID) -> TabModel? { tabsBySurface[surface] }
    /// The shell's reported folder (OSC 7); a remote terminal's is never a local cwd.
    public func noteTerminalDirectory(_ directory: String?, surface: SurfaceID) {
        guard let tab = tabsBySurface[surface], tab.kind != .remoteTerminal else { return }
        tab.setObservedCwd(directories.note(directory, surface: surface))
    }
    public func tab(terminal: TerminalID) -> TabModel? { tabsBySurface.values.first { $0.terminalID == terminal } }
    /// The tab with durable id `id` (`TabModel.id`).
    public func tab(id: String) -> TabModel? { tabsBySurface.values.first { $0.id == id } }
    public func tabGroup(_ id: TabGroupID) -> TabGroupModel? { tabGroupsByID[id] }
    public func group(_ id: WorkspaceGroupID) -> WorkspaceGroupModel? { groups.first { $0.id == id } }
    public func profile(_ id: ProfileID) -> ProfileModel? { profiles.first { $0.id == id } }

    /// The pane currently holding `surface`.
    /// The workspace whose screens hold pane `handle`.
    public func workspace(containing handle: PaneID) -> WorkspaceModel? {
        workspaces.first { $0.screens.contains { $0.panes.contains { $0.handle == handle } } }
    }

    public func pane(containing surface: SurfaceID) -> PaneModel? {
        panesByHandle.values.first { pane in pane.tabs.contains { $0.surface == surface } }
    }

    // MARK: Snapshot

    /// Replaces the confirmed tree, reusing records by durable identity,
    /// then shows the pending intents on it again.
    public func apply(snapshot tree: DaemonTree) {
        withOverlayLifted(snapshot: true) {
            applyTree(tree)
            if isProvisional { isProvisional = false }
            if !isLoaded {
                isLoaded = true
                DaemonLaunchTimings.shared.mark("daemon.first_tree_applied")
            }
            if restoredEpoch != connectionEpoch {
                restoredEpoch = connectionEpoch
                restoredTabIDs = currentTabIDs
            }
            structureChanged()
        }
        workspaceListMayHaveChanged()
        runAppliedWaiters(nil, snapshot: true)
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
            isProvisional = true
            // Launch snapshot tabs are restored tabs (pages made from them reload).
            restoredTabIDs = currentTabIDs
            structureChanged()
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
        if let reordered = reconcile(workspaces, with: tree.workspaces, id: WorkspaceModel.identity, make: WorkspaceModel.init,
                                     update: { $0.update($1) }) {
            workspaces = reordered
        }
    }

    /// Seeds agent state (`list-agents`), e.g. after connect.
    public func apply(agents: [AgentStatus]) {
        agentsBySurface = Dictionary(agents.map { ($0.surface, $0) }, uniquingKeysWith: { $1 })
        for (surface, tab) in tabsBySurface { tab.setAgent(agentsBySurface[surface]) }
    }

    /// Records a completed handshake before its `.connected` event drains,
    /// so capability checks right after connect see this daemon.
    public func noteHandshake(_ identity: DaemonIdentity) {
        if self.identity != identity { self.identity = identity }
    }

    /// Marks the connection permanently failed (incompatible daemon).
    public func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    // MARK: Derived state

    /// Rebuilds lookup indexes and the sidebar flattening after a structural change.
    func structureChanged() {
        var tabs: [SurfaceID: TabModel] = [:]
        var panes: [PaneID: PaneModel] = [:]
        var screens: [ScreenID: ScreenModel] = [:]
        var byHandle: [WorkspaceHandle: WorkspaceModel] = [:]
        var byKey: [WorkspaceKey: WorkspaceModel] = [:]
        var tabGroups: [TabGroupID: TabGroupModel] = [:]
        for workspace in workspaces {
            byHandle[workspace.handle] = workspace
            if let key = workspace.key { byKey[key] = workspace }
            for screen in workspace.screens {
                screens[screen.handle] = screen
                for pane in screen.panes {
                    panes[pane.handle] = pane
                    for group in pane.tabGroups { tabGroups[group.id] = group }
                    for tab in pane.tabs {
                        tabs[tab.surface] = tab
                        if tab.agent == nil, let agent = agentsBySurface[tab.surface] { tab.setAgent(agent) }
                        tab.setObservedCwd(directories[tab.surface])
                    }
                }
            }
        }
        tabsBySurface = tabs
        panesByHandle = panes
        screensByHandle = screens
        workspacesByHandle = byHandle
        workspacesByKey = byKey
        tabGroupsByID = tabGroups
        recomputeSidebar()
        session.overlay(workspaces)
    }

    /// Runs `onWorkspaceListChanged` when the workspace list differs from
    /// the last one reported (outside a batch, once loaded).
    func workspaceListMayHaveChanged() {
        guard applyDepth == 0, isLoaded, let hook = onWorkspaceListChanged else { return }
        let list = sidebarSections.flatMap(\.workspaces).map(\.id) + ["|"] + workspaces.map(\.id)
        guard list != notifiedWorkspaceList else { return }
        notifiedWorkspaceList = list
        hook()
    }

    func recomputeSidebar() {
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
