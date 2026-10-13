import CmuxCloud
import CmuxCloudResizeCore
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import AppKit
import Foundation
import SwiftUI

/// Loads the visible fleet for the Machines tab and merges changes pushed by the presence
/// `vms` sync collection (``CloudVMSyncSubscriber``); mutations use CloudVMActionLauncher.
@MainActor
final class MachinesPanelViewModel: ObservableObject {
    @Published private(set) var machines: [MachineSnapshot] = []
    @Published private(set) var plan: MachinePlanSnapshot?
    @Published private(set) var isLoading = false { didSet { if !isLoading { isRefreshingOnRequest = false } } }
    /// A refresh someone asked for (`refresh(tree:)`) is loading, as opposed to the poll.
    @Published private(set) var isRefreshingOnRequest = false
    /// A rename keeps the Cloud Machines section visibly refreshing while its
    /// optimistic label is waiting for the command completion callback.
    @Published private(set) var isRenamingMachine = false
    /// Labels submitted by the user remain over the sidebar projection until
    /// an authoritative list response confirms the same value.
    private var optimisticLabels: [String: String] = [:]
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var lastErrorDescription: String?
    /// Classified list failure for the matching sign-in, plan, or retry presentation.
    @Published private(set) var listProblem: CloudListProblem?
    /// Mirrors coordinator reachability; offline is not a failed list read.
    @Published private(set) var isNetworkOffline = false
    /// Set by recovery reads, never routine polls, so a real outage does not flicker.
    @Published private(set) var isRecoveringList = false
    /// Consecutive transient failures before the first successful list read.
    private(set) var initialTransientFailureCount = 0
    /// Per-machine coderouter spend from the last successful usage fetch.
    @Published private(set) var usageByMachineID: [String: MachineUsageSnapshot] = [:]

    /// Surface catalog: machines, their resources, and local projections.
    @Published private(set) var catalog: SurfaceCatalogSnapshot = .empty
    /// Local workspaces in sidebar order for terminal grouping.
    @Published private(set) var localWorkspaces: [CloudTreeLocalWorkspace] = []
    /// Machine ids to unread terminal ids from notification syncs.
    @Published private(set) var unreadTerminalIDs: [String: Set<String>] = [:]
    private var unreadObserver: NSObjectProtocol?
    /// Last failure from a tree verb (open, new terminal, …); shown in the
    /// control bar's help text, cleared by the next successful refresh.
    @Published private(set) var treeErrorDescription: String?
    /// Set when `treeErrorDescription` is trusted, user-facing guidance rather
    /// than an upstream failure; only that copy is shown verbatim.
    @Published private(set) var treeHint: String?
    /// In-flight and failed creates appear above the fleet; the shared
    /// coordinator keeps them visible across panels and panel closure.
    var pendingCreates: [MachineCreateOperation] { createCoordinator.operations }
    var adoptedOperationIDs: [String: UUID] { createCoordinator.adoptedOperationIDs }

    let createCoordinator: MachineCreateCoordinator
    /// How the view model reads local workspaces; injectable for tests.
    var localWorkspacesProvider: @MainActor () -> [CloudTreeLocalWorkspace] = {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        let selected = tabManager.selectedTabId
        return tabManager.tabs.map { CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == selected) }
    }
    func endOperation() {
        if wantsPolling { refresh() }
    }

    /// Opens one local Cloud Agent terminal and owns the asynchronous work for
    /// the lifetime of this panel model. Selecting another agent cancels the
    /// previous launch instead of leaving an unowned task behind the view.
    func launchCloudAgent(_ agent: CloudAgentSkillLauncher.CodingAgent) {
        cloudAgentTask?.cancel()
        cloudAgentTask = Task { @MainActor [weak self] in
            defer { self?.cloudAgentTask = nil }
            do { _ = try await CloudAgentSkillLauncher.openAgent(agent) }
            catch is CancellationError { return }
            catch { self?.noteTreeFailure(error.localizedDescription) }
            self?.endOperation()
        }
    }

    /// Cancels a launch when the Machines panel leaves the view hierarchy.
    func cancelCloudAgentTask() {
        cloudAgentTask?.cancel()
        cloudAgentTask = nil
    }

    func noteTreeFailure(_ description: String) {
        // A tree failure is an event, not a persistent state banner. Clear a
        // prior dismissal so repeating the same ownership hint remains
        // visible on the next invalid attempt.
        AppDelegate.shared?.cloudBannerDismissalStore.clear(id: "machines.tree-error")
        treeHint = nil
        treeErrorDescription = description
    }

    func noteTreeHint(_ hint: String) {
        noteTreeFailure(hint)
        treeHint = hint
    }

    /// Projects the coordinator's typed reachability event into this panel's
    /// local presentation. The panel owns presentation state; the coordinator
    /// remains the sole network-state owner.
    private func applyNetworkChange(_ online: Bool) {
        #if DEBUG
        cmuxDebugLog("cloud.machines.list network online=\(online) wantsPolling=\(wantsPolling)")
        #endif
        isNetworkOffline = !online
        if online {
            if wantsPolling { startPolling() }
            return
        }
        clearUnavailableMetrics()
        // Retire the transport; `wantsPolling` survives so online restarts it.
        pausePolling()
    }

    /// A recovery read: a transient failure reads as reconnecting until it settles.
    func recoverList() {
        refresh()
        #if DEBUG
        cmuxDebugLog("cloud.machines.list recover started=\(isRecoveringList) problem=\(String(describing: listProblem))")
        #endif
    }

    var refreshTask: Task<Void, Never>?
    var statsID: UUID?
    let client: VMClient?
    /// The realtime `vms` stream for this panel; nil when the composition root
    /// has no auth coordinator (tests), in which case the list only polls.
    let vmSync: CloudVMSyncSubscriber?
    /// True while the `vms` socket is delivering frames. The routine poll
    /// stretches to ``streamingPollInterval`` because the stream carries
    /// changes; the poll then only covers `limits` and anything the stream lost.
    private(set) var isVMSyncConnected = false
    /// The refresh generation and pin scope the running stream was started
    /// under; a frame from an older start is dropped like a stale list read.
    var vmSyncGeneration: UInt64 = 0
    var vmSyncScope: String?
    let isCloudEnabled: @MainActor () -> Bool
    let pollingClock: any Clock<Duration>
    /// Posts `NSWorkspace.didWakeNotification`; injectable for tests.
    let wakeNotificationCenter: NotificationCenter
    /// Posts `NSApplication.didBecomeActiveNotification`; injectable for tests.
    let lifecycleNotificationCenter: NotificationCenter
    private var networkTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?
    var statsTask: Task<Void, Never>?
    private var resourceUpdatesTask: Task<Void, Never>?
    let resourceStats: VMResourceStatsStore?
    var machineIndexByID: [String: Int] = [:]
    var usageTask: Task<Void, Never>?
    private var cloudAgentTask: Task<Void, Never>?
    var usageFailureCount = 0
    var usageRetryNotBefore: Date?
    /// One-shot timer armed at the exact next free-access transition (a
    /// countdown day-boundary or an expiry). Expiry is client-computable from
    /// createdAt + window, so rows flip at the boundary itself — scheduling,
    /// not polling; the slow poll only covers changes made elsewhere.
    var freeAccessTransitionTask: Task<Void, Never>?
    var freeAccessWindowDays = 0
    /// Last plan limits the list returned; the banner countdown re-derives from
    /// these on every local recompute without another round trip.
    var lastLimits: VMPlanLimits?
    var memoryOptionsMb: [Int] { lastLimits?.memoryOptionsMb ?? [] }
    var maxDiskMb: Int? { lastLimits?.maxDiskMb }
    var maxMemoryMb: Int? { lastLimits?.maxMemoryMb }
    var maxVcpus: Int? { lastLimits?.maxVcpus }
    var resourcePool: CloudVMResourcePool? { lastLimits?.resourcePool }
    /// Conservative resize ceilings for control planes that predate the
    /// explicit max* fields. The accepted memory ladder is the best fallback
    /// because it already reflects Go, Pro, Team, and Max.
    var resizeFallbackMaxMemoryMb: Int {
        let productCeiling: Int
        switch lastLimits?.planId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "max": productCeiling = 64 * 1_024
        case "go": productCeiling = 4 * 1_024
        case "free": productCeiling = 8 * 1_024
        default: productCeiling = 16 * 1_024
        }
        // A pre-ceiling server may still send the complete ladder. Keep the
        // fallback bounded by the product tier so Pro never exposes Max-only
        // 12/16-vCPU targets while maxMemoryMb is absent.
        return min(memoryOptionsMb.max() ?? productCeiling, productCeiling)
    }
    var resizeFallbackMaxDiskGiB: Int {
        switch lastLimits?.planId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "max": return 256
        case "go": return 16
        default: return 128
        }
    }
    var lockedMemoryOptionsMb: [Int]? { lastLimits?.lockedMemoryOptionsMb }
    var memoryUpgradePlanId: String? { lastLimits?.memoryUpgradePlanId }
    var memoryUpgradePlansByMb: [String: String]? { lastLimits?.memoryUpgradePlansByMb }
    var vcpusByMemoryMb: [String: Int]? { lastLimits?.vcpusByMemoryMb }
    var diskByMemoryMb: [String: Int]? { lastLimits?.diskByMemoryMb }
    private var authScopeObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var lifecycleObserver: NSObjectProtocol?
    private var featureFlagObserver: CloudFeatureAvailabilityObserver?
    var wantsPolling = false
    private var treeChangeObserver: NSObjectProtocol?
    private var createChangeObserver: NSObjectProtocol?
    var treeTask: Task<Void, Never>?
    let machineRefreshes = CloudMachineRefreshCoordinator { await SurfaceCatalog.shared.refreshPortDiscovery(machine: $0) }
    /// Explicit machine pins and the stable fleet order; nil keeps fleet order.
    let machinePinStore: CloudMachinePinStore?
    private let catalogProvider: @MainActor () -> SurfaceCatalogSnapshot
    var awaitingCatalogScope = false

    init(
        createCoordinator: MachineCreateCoordinator? = nil,
        machinePinStore: CloudMachinePinStore? = nil,
        resourceStats: VMResourceStatsStore? = nil,
        client: VMClient? = nil,
        vmSync: CloudVMSyncSubscriber? = nil,
        pollingClock: any Clock<Duration> = ContinuousClock(),
        wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lifecycleNotificationCenter: NotificationCenter = .default,
        isCloudEnabled: @escaping @MainActor () -> Bool = { CloudMachinesFeature.isEnabled },
        // Another team's machines stay in the catalog while open surfaces use
        // them; the sidebar lists only the selected team's fleet.
        catalogProvider: @escaping @MainActor () -> SurfaceCatalogSnapshot = {
            MachinesPanelViewModel.catalog(
                SurfaceCatalog.shared.snapshot,
                hiding: CmuxTuiSurfaceProviderRegistry.shared.foreignTeamMachineIDs
            )
        },
        localWorkspacesProvider: (@MainActor () -> [CloudTreeLocalWorkspace])? = nil
    ) {
        let networkClient = client ?? VMClient.shared
        self.client = networkClient
        self.vmSync = vmSync
        self.pollingClock = pollingClock
        self.wakeNotificationCenter = wakeNotificationCenter
        self.lifecycleNotificationCenter = lifecycleNotificationCenter
        self.isCloudEnabled = isCloudEnabled
        self.resourceStats = resourceStats ?? networkClient?.resourceStats ?? VMClient.shared?.resourceStats
        self.machinePinStore = machinePinStore
        self.catalogProvider = catalogProvider
        if let localWorkspacesProvider { self.localWorkspacesProvider = localWorkspacesProvider }
        // Resolve the main-actor-isolated default here, not in a default argument.
        let createCoordinator = createCoordinator ?? .shared
        self.createCoordinator = createCoordinator
        let finishedUserInfoKey = MachineCreateCoordinator.finishedUserInfoKey
        createChangeObserver = NotificationCenter.default.addObserver(
            forName: MachineCreateCoordinator.didChangeNotification,
            object: createCoordinator,
            queue: .main
        ) { [weak self] notification in
            let finished = notification.userInfo?[finishedUserInfoKey] as? MachineCreateCoordinator.Finished
            MainActor.assumeIsolated { self?.createsDidChange(finished: finished) }
        }
        authScopeObservers = [
            Notification.Name.cmuxCloudVMAccessDidEnd,
            .cmuxCloudTeamScopeDidChange,
            .cmuxCloudTeamScopeReady,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .cmuxCloudVMAccessDidEnd { self.resetForAuthTransition() }
                    else if name == .cmuxCloudTeamScopeDidChange { self.beginTeamScopeTransition() }
                    else { self.finishTeamScopeTransition() }
                }
            }
        }
        wakeObserver = wakeNotificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        lifecycleObserver = lifecycleNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        }
        featureFlagObserver = CloudFeatureAvailabilityObserver(
            isEnabled: isCloudEnabled,
            didChange: { [weak self] enabled in
                guard let self else { return }
                if enabled, self.wantsPolling { self.startPolling() }
                else { self.pausePolling() }
            }
        )
        treeChangeObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (`queue: .main`), which is the main actor.
            MainActor.assumeIsolated { self?.scheduleCatalogRead() }
        }
        if let unreadObserver { NotificationCenter.default.removeObserver(unreadObserver) }
        unreadObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudNotificationUnreadDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readUnreadTerminalIDs() }
        }
        readUnreadTerminalIDs()
        vmSync?.setEventHandler { [weak self] event in
            self?.vmSyncDidEmit(event)
        }
        if let networkClient {
            networkTask = Task { [weak self, networkClient] in
                let changes = await networkClient.networkChanges()
                for await online in changes {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.applyNetworkChange(online)
                }
            }
        }
        if let resourceStats = self.resourceStats {
            let changes = resourceStats.changes()
            resourceUpdatesTask = Task { [weak self] in
                for await _ in changes.events {
                    guard !Task.isCancelled else { return }
                    self?.applyResourceStats(machineIDs: changes.takeMachineIDs())
                }
            }
        }
    }
    /// Catalog changes arrive in bursts (a link snapshot upserts dozens of resources, a
    /// projection records, titles tick). Collapse them to one `readCatalog()` per
    /// main-runloop turn, and none at all while the outline is being dragged — the
    /// suppressed read runs once when the drag ends.
    private var pendingCatalogRead = false
    private var catalogReadSuppressedByDrag = false
    private(set) var isTreeDragging = false
    func scheduleCatalogRead() {
        guard !pendingCatalogRead else { return }
        pendingCatalogRead = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingCatalogRead = false
            if self.isTreeDragging {
                self.catalogReadSuppressedByDrag = true
                return
            }
            self.readCatalog()
        }
    }
    func setTreeDragging(_ dragging: Bool) {
        guard isTreeDragging != dragging else { return }
        isTreeDragging = dragging
        if !dragging, catalogReadSuppressedByDrag {
            catalogReadSuppressedByDrag = false
            readCatalog()
        }
    }
    deinit {
        networkTask?.cancel()
        refreshTask?.cancel()
        pollTask?.cancel()
        statsTask?.cancel()
        usageTask?.cancel()
        cloudAgentTask?.cancel()
        treeTask?.cancel()
        freeAccessTransitionTask?.cancel()
        resourceUpdatesTask?.cancel()
        for observer in authScopeObservers + [treeChangeObserver, unreadObserver, createChangeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let wakeObserver { wakeNotificationCenter.removeObserver(wakeObserver) }
        if let lifecycleObserver { lifecycleNotificationCenter.removeObserver(lifecycleObserver) }
    }

    func updateListRefreshPresentation(isLoading loading: Bool? = nil, isRecovering recovering: Bool? = nil) {
        if let loading { isLoading = loading }
        if let recovering { isRecoveringList = recovering }
    }

    func clearListLoadingIfIdle() {
        if refreshTask == nil { isLoading = false }
    }
    /// Mirrors the coordinator's rows. A completion also re-reads the fleet so
    /// the real machine row replaces the pending one without waiting for the
    /// slow poll; a machine that was created but could not be opened lands its
    /// reason in the control bar, where the person will look for it.
    private func createsDidChange(finished: MachineCreateCoordinator.Finished?) {
        objectWillChange.send()
        guard let finished else { return }
        if case .createdButOpenFailed(let machineID, let output) = finished.outcome {
            // One line: the control bar shows two at most, so the reason comes
            // first and the way out second.
            let format = String(
                localized: "machines.pending.createdOpenFailed.bar",
                defaultValue: "%1$@ was created, but opening it failed: %2$@ Open it from the list."
            )
            treeErrorDescription = String(format: format, machineID, MachineCreateOperation.headline(ofOutput: output) ?? output)
        }
        if wantsPolling { refresh() }
    }
    /// Publishes the catalog's current value and the local workspace list. Cheap
    /// (a value read), so every change notification may call it.
    func readCatalog() {
        catalog = scopedCatalogSnapshot()
        // Catalog discoveries join the remembered fleet order as they appear, so a
        // machine the list endpoint has not returned yet still has a stable slot.
        machinePinStore?.remember(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(machines, catalog: catalog).map(\.id))
        createCoordinator.reconcileAuthoritativeState(
            machineIDs: Set(machines.map(\.id)),
            catalogMachineIDs: Set(catalog.machines.compactMap { $0.id.cloudMachineID })
        )
        localWorkspaces = localWorkspacesProvider()
        // The unread index and the catalog change on the same accepted daemon
        // state, so a catalog read also refreshes it. Cheap: a dictionary read.
        readUnreadTerminalIDs()
    }

    /// Refreshes the local workspace projection with the selection that was just committed.
    /// The selection publisher fires from `willSet`, so reading the tab manager here can still
    /// return the previous workspace and leave the Cloud tree highlight one selection behind.
    func refreshLocalWorkspaces(selectedWorkspaceID: UUID?) {
        let updated = localWorkspacesProvider().map { workspace in
            CloudTreeLocalWorkspace(
                id: workspace.id,
                title: workspace.title,
                isSelected: workspace.id == selectedWorkspaceID
            )
        }
        guard updated != localWorkspaces else { return }
        localWorkspaces = updated
    }
    private func readUnreadTerminalIDs() {
        let unread = CloudNotificationSyncHub.shared.unreadTerminalIDs
        guard unread != unreadTerminalIDs else { return }
        #if DEBUG
        cmuxDebugLog("cloud.notifications.panelUnread machines=\(unread.count) terminals=\(unread.values.reduce(0) { $0 + $1.count })")
        #endif
        unreadTerminalIDs = unread
    }
    /// The explicit Refresh verb re-syncs every provider and reads the catalog.
    func refreshTree(force: Bool) {
        treeTask?.cancel()
        treeTask = Task { [weak self] in
            if force {
                await SurfaceCatalog.shared.refreshAll()
            }
            guard !Task.isCancelled, let self else { return }
            self.treeErrorDescription = nil
            self.readCatalog()
        }
    }
    /// `refresh(tree: true)` refreshes machines, stats, and the catalog.
    func refresh(tree forceTree: Bool) {
        recoverList()
        refreshTree(force: forceTree)
        isRefreshingOnRequest = isLoading
    }
    func refreshMachine(_ machine: SurfaceMachineID) { machineRefreshes.refresh(machine) }
    nonisolated static func usageBackoffDelay(failureCount: Int) -> TimeInterval {
        [30, 30, 60, 120, 300][min(max(failureCount, 0), 4)]
    }
    /// The one place usage lands: the lookup and the row snapshots move together.
    func applyUsage(_ usage: [String: MachineUsageSnapshot]) {
        usageByMachineID = usage
        machines = MachineSnapshotBuilder.applyingUsage(to: machines, usage: usage)
    }

    /// Projects a submitted label into the sidebar immediately. The next
    /// authoritative list refresh replaces it if the command was rejected.
    func beginOptimisticRename(id: String, label: String?) {
        optimisticLabels[id] = label ?? ""
        machines = MachineSnapshotBuilder.applyingLabel(to: machines, machineID: id, label: label)
        isRenamingMachine = true
        // Catalog-only machines are rendered by `sidebarMachines`, so notify
        // those readers even when the list response does not contain this id.
        objectWillChange.send()
    }

    func finishOptimisticRename() {
        isRenamingMachine = false
    }

    func applyingOptimisticLabels(to snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        snapshots.map { snapshot in
            guard let encoded = optimisticLabels[snapshot.id] else { return snapshot }
            var next = snapshot
            next.label = encoded.isEmpty ? nil : encoded
            return next
        }
    }

    private func reconcileOptimisticLabels(with authoritative: [MachineSnapshot]) {
        for snapshot in authoritative {
            guard let encoded = optimisticLabels[snapshot.id] else { continue }
            let expected = encoded.isEmpty ? nil : encoded
            if snapshot.label == expected { optimisticLabels.removeValue(forKey: snapshot.id) }
        }
    }

    func optimisticallyRenameMachine(id: String, label: String?) {
        beginOptimisticRename(id: id, label: label)
    }
    static let pollInterval: Duration = .seconds(45)
    /// The routine cadence while the `vms` stream is connected: the stream
    /// carries machine changes, so the poll only reconciles `limits` and any
    /// change the stream lost.
    static let streamingPollInterval: Duration = .seconds(300)
    /// The cadence the poll loop sleeps for next; re-read on every iteration.
    var routinePollInterval: Duration {
        isVMSyncConnected ? Self.streamingPollInterval : Self.pollInterval
    }
    static let initialTransientFailureLimit = 3
    /// A refresh asked for while one is in flight runs again afterwards: a create that lands
    /// mid-poll must still replace its pending row with the real machine now, not on the next 45 s sweep.
    var refreshRequestedWhileLoading = false
    /// A queued automatic refresh promotes the current request to recovery presentation and keeps that intent for the follow-up read.
    var refreshRequestedWhileLoadingIsRecovery = false
    /// Stream changes that arrived while a REST read was in flight, replayed on
    /// top of that read's page; nil while no read is in flight.
    var streamChangesDuringRestRead: [(upserts: [VMSummary], deletions: Set<String>, authoritative: Bool)]?
    /// Invalidates refresh completions when the Cloud gate closes. A cancelled URLSession task may
    /// still resume on the main actor, so cancellation alone is not enough to prevent stale rows or follow-up work.
    var refreshGeneration: UInt64 = 0
    /// Sleeps until the earliest upcoming transition across the fleet, then
    /// recomputes the free-access facet locally and re-arms for the next one.
    func scheduleFreeAccessTransition(now: Date = Date()) {
        freeAccessTransitionTask?.cancel()
        freeAccessTransitionTask = nil
        guard freeAccessWindowDays > 0 else { return }
        let windowDays = freeAccessWindowDays
        let next = machines
            .compactMap { MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: $0.createdAt, windowDays: windowDays, now: now) }
            .min()
        guard let next else { return }
        // A hair past the boundary so the recompute lands on the new side.
        let delay = max(next.timeIntervalSince(now), 0) + 0.5
        freeAccessTransitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            self.machines = MachineSnapshotBuilder.applyingFreeAccess(to: self.machines, windowDays: windowDays, now: now)
            self.plan = MachineSnapshotBuilder.planSnapshot(
                // Keep the server's count from the last list read; only the free-access state moved.
                activeCount: self.plan?.activeCount ?? MachineSnapshotBuilder.activeCount(of: self.machines),
                limits: self.lastLimits, machines: self.machines, now: now
            )
            self.scheduleFreeAccessTransition(now: now)
        }
    }

    /// Drop every locally cached machine and in-flight sample when auth ends.
    /// This is intentionally callable by the panel as well as the sign-out
    /// notification observer so a signed-out panel can never render a stale
    /// fleet while SwiftUI is catching up with the auth projection.
    func resetForAuthTransition() {
        resourceStats?.reset()
        pausePolling()
        freeAccessWindowDays = 0
        lastLimits = nil
        machines = []
        machineIndexByID.removeAll()
        usageByMachineID = [:]
        catalog = .empty
        localWorkspaces = []
        treeErrorDescription = nil
        plan = nil
        createCoordinator.cancelAllForAuthTransition()
        lastErrorDescription = nil
        listProblem = nil
        hasLoadedOnce = false
        initialTransientFailureCount = 0
        isLoading = false
    }

    /// Clears old-team rows as soon as auth announces a scope transition.
    private func beginTeamScopeTransition() {
        resetForAuthTransition()
        machinePinStore?.refreshScope()
        awaitingCatalogScope = true
    }

    /// Re-enables catalog rows once the registry has discovered the new team.
    /// Remote workspace details continue refreshing independently.
    private func finishTeamScopeTransition() {
        awaitingCatalogScope = false
        readCatalog()
        if wantsPolling { startPolling() }
    }

    /// Retire old requests before changing pin scope. Catalog discoveries are
    /// admitted again only after the shared registry refreshes the new account.
    @discardableResult
    func refreshAccountScope(
        refreshCatalog: @escaping @MainActor () async -> Bool = { await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true) }
    ) -> Task<Void, Never> {
        resetForAuthTransition()
        machinePinStore?.refreshScope()
        awaitingCatalogScope = true
        let generation = refreshGeneration
        let task = Task { @MainActor [weak self] in
            let accepted = await refreshCatalog()
            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            if accepted { self.awaitingCatalogScope = false }
            self.readCatalog()
            self.treeTask = nil
        }
        treeTask = task
        if wantsPolling { startPolling() }
        return task
    }

    func scopedCatalogSnapshot() -> SurfaceCatalogSnapshot {
        let snapshot = catalogProvider()
        guard awaitingCatalogScope else { return snapshot }
        // The Cloud registry owns only Cloud account scope. The device registry
        // independently retires unauthorized Macs, so a failed Cloud refresh
        // must not hide live device rows and their already-open projections.
        let independentMachines = snapshot.machines.filter { $0.id.cloudMachineID == nil }.map(\.id)
        let allowed = Set(machines.map { SurfaceMachineID.cloud($0.id) }).union(independentMachines)
        var scoped = snapshot
        scoped.machines.removeAll { !allowed.contains($0.id) }
        scoped.resources.removeAll { !allowed.contains($0.machine) }
        scoped.projections.removeAll { !allowed.contains($0.resource.machine) }
        scoped.pendingWorkspaceDeletions = scoped.pendingWorkspaceDeletions?.filter { allowed.contains($0.key) }
        scoped.pendingWorkspaceCreations = scoped.pendingWorkspaceCreations?.filter { allowed.contains($0.key) }
        return scoped
    }

    /// Read the current shared resource owner, retaining its resize and list fences.
    func applyResourceStats(machineIDs: Set<String>?) {
        guard isCloudEnabled(), let resourceStats else { return }
        for id in machineIDs ?? Set(machineIndexByID.keys) {
            guard let index = machineIndexByID[id], machines.indices.contains(index),
                  machines[index].id == id, machines[index].capabilities.stats else { continue }
            let stats = resourceStats.stats(for: id)
            if machines[index].stats != stats { machines[index].stats = stats }
        }
    }

    func pausePolling() {
        stopVMSync()
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshRequestedWhileLoading = false
        refreshRequestedWhileLoadingIsRecovery = false
        refreshGeneration &+= 1
        streamChangesDuringRestRead = nil
        isLoading = false
        isRenamingMachine = false
        optimisticLabels.removeAll()
        isRecoveringList = false
        statsTask?.cancel(); statsTask = nil; statsID = nil
        usageTask?.cancel(); usageTask = nil
        usageFailureCount = 0
        usageRetryNotBefore = nil
        treeTask?.cancel(); treeTask = nil
        machineRefreshes.cancelAll()
        freeAccessTransitionTask?.cancel(); freeAccessTransitionTask = nil
    }

    func clearUnavailableMetrics() {
        if let resourceStats {
            for id in machineIndexByID.keys {
                _ = resourceStats.finishRead(resourceStats.beginRead(machineID: id), stats: nil)
            }
            applyResourceStats(machineIDs: nil)
        }
        usageByMachineID = [:]
        machines = MachineSnapshotBuilder.applyingUsage(to: machines, usage: [:])
    }


    func applyRefreshResult(_ result: Result<VMListPage, Error>, generation: UInt64, scope: String?) {
        guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier, isCloudEnabled() else { return }
        do {
            let page = try result.get()
            try Task.checkCancellation()
            guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier,
                  isCloudEnabled() else { return }
            let previous = resourceStats?.snapshot ?? [:]
            let freeAccessWindowDays = page.limits?.freeAccessWindowDays ?? 0
            self.freeAccessWindowDays = freeAccessWindowDays
            var snapshots = page.vms.map {
                MachineSnapshotBuilder.snapshot(
                    from: $0,
                    freeAccessWindowDays: freeAccessWindowDays,
                    previousStats: previous[$0.id]
                )
            }
            snapshots = MachineSnapshotBuilder.applyingUsage(to: snapshots, usage: usageByMachineID)
            reconcileOptimisticLabels(with: snapshots)
            snapshots = applyingOptimisticLabels(to: snapshots)
            // The authoritative fleet plus catalog-only rows is the complete
            // visible set: a pin whose machine is gone from both is pruned.
            machinePinStore?.reconcile(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(snapshots, catalog: scopedCatalogSnapshot()).map(\.id))
            machineIndexByID = Dictionary(uniqueKeysWithValues: snapshots.enumerated().map { ($0.element.id, $0.offset) })
            machines = snapshots
            lastLimits = page.limits
            // The page was read before any stream change recorded since it
            // started; replay those so a newer change is never undone.
            let streamed = streamChangesDuringRestRead ?? []
            streamChangesDuringRestRead = nil
            for change in streamed {
                applyVMChanges(upserts: change.upserts, deletions: change.deletions, authoritative: change.authoritative)
            }
            snapshots = machines
            scheduleFreeAccessTransition()
            refreshStats()
            refreshUsage()
            readCatalog()
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: page.activeMachineCount, limits: page.limits, machines: snapshots)
            lastErrorDescription = nil
            listProblem = nil
            initialTransientFailureCount = 0
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .notConnectedToInternet {
            // The read coordinator's offline verdict (URLSession transport errors
            // arrive as backendUnreachable): not a list failure; offline owns it.
            return
        } catch let error as VMClientError {
            guard !Task.isCancelled, generation == refreshGeneration,
                  scope == machinePinStore?.scopeIdentifier else { return }
            if case .notSignedIn = error {
                machines = []
                machineIndexByID.removeAll()
                plan = nil
                lastErrorDescription = nil
                listProblem = nil
                hasLoadedOnce = false
                initialTransientFailureCount = 0
                isLoading = false
                return
            }
            lastErrorDescription = String(describing: error)
            listProblem = Self.classifyListFailure(error)
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration,
                  scope == machinePinStore?.scopeIdentifier else { return }
            lastErrorDescription = String(describing: error)
            listProblem = .unreachable
        }
        if listProblem == .unreachable, !hasLoadedOnce {
            initialTransientFailureCount = min(
                initialTransientFailureCount + 1,
                Self.initialTransientFailureLimit
            )
        } else if listProblem != .unreachable {
            initialTransientFailureCount = 0
        }
        hasLoadedOnce = hasLoadedOnce || listProblem != .unreachable
        #if DEBUG
        cmuxDebugLog("cloud.machines.list settled count=\(machines.count) problem=\(String(describing: listProblem))")
        #endif
    }

    // MARK: - Realtime `vms` stream

    /// Starts (or keeps) the stream under the current account and team, fenced
    /// to this refresh generation and pin scope. Polling owns the lifecycle:
    /// the stream lives exactly while the panel polls.
    func startVMSync() {
        guard let vmSync else { return }
        vmSyncGeneration = refreshGeneration
        vmSyncScope = machinePinStore?.scopeIdentifier
        vmSync.start()
    }

    func stopVMSync() {
        // Cleared first so the stop's own `.disconnected` event finds nothing
        // to change and does not re-arm a poll loop the caller is retiring.
        isVMSyncConnected = false
        vmSync?.stop()
    }

    /// Starts recording stream changes for the REST read about to begin.
    func beginRestReadStreamCapture() {
        streamChangesDuringRestRead = []
    }

    private func vmSyncDidEmit(_ event: CloudVMSyncSubscriber.Event) {
        guard vmSyncGeneration == refreshGeneration, vmSyncScope == machinePinStore?.scopeIdentifier,
              isCloudEnabled() else { return }
        switch event {
        case .connected:
            setVMSyncConnected(true)
            // Changes during the gap are not replayed in full, and the REST
            // list is the only source of `limits`: read it on every (re)connect.
            refresh(routinePoll: true)
        case .disconnected:
            setVMSyncConnected(false)
        case .snapshot(let records, let backfilled):
            // An unbackfilled snapshot holds only rows written since the
            // collection shipped: it may add and update, never remove.
            applyVMChanges(
                upserts: records.compactMap(\.summary),
                deletions: backfilled ? Set(records.filter(\.deleted).map(\.id)) : [],
                authoritative: backfilled
            )
        case .delta(let records):
            applyVMChanges(
                upserts: records.compactMap(\.summary),
                deletions: Set(records.filter(\.deleted).map(\.id)),
                authoritative: false
            )
        }
    }

    private func setVMSyncConnected(_ connected: Bool) {
        guard isVMSyncConnected != connected else { return }
        isVMSyncConnected = connected
        // The routine cadence changed: re-arm the sleeping poll so the new
        // interval applies now instead of after the old one elapses.
        guard pollTask != nil else { return }
        pollTask?.cancel(); pollTask = nil
        armPollLoop()
    }

    /// Merges pushed machine changes into the rows in place. `upserts` replace
    /// their row by id or insert in createdAt-descending order (the list
    /// endpoint's order); `deletions` remove rows; `authoritative` means
    /// `upserts` is the complete fleet, so every other row is removed too.
    /// Rows rebuild through ``MachineSnapshotBuilder`` with the last list's
    /// free-access window, the shared stats store and the last usage, then the
    /// same post-list reconcile runs as after a REST read. `limits` never
    /// change here; only ``refresh(routinePoll:)`` carries them.
    /// A `vms` stream record carries the row's own columns only; the creator's
    /// name, the pool claim, agent updates and the free-access expiry come
    /// from the REST list. Keep the existing row's values for those until the
    /// next list read replaces them.
    static func keepingListOnlyFields(of existing: MachineSnapshot, in streamed: MachineSnapshot, streamed summary: VMSummary) -> MachineSnapshot {
        let createdBy: VMCreator? = if let creator = streamed.createdBy, creator.userId != existing.createdBy?.userId {
            creator
        } else {
            existing.createdBy ?? streamed.createdBy
        }
        var next = MachineSnapshot(
            id: streamed.id,
            provider: streamed.provider,
            image: streamed.image,
            isDesktop: streamed.isDesktop,
            capabilities: streamed.capabilities,
            activity: streamed.activity,
            createdAt: streamed.createdAt,
            createdBy: createdBy,
            label: streamed.label,
            slug: streamed.slug,
            freeAccess: summary.freeAccessExpiresAt == nil ? existing.freeAccess : streamed.freeAccess,
            stats: streamed.stats,
            resourceReservation: streamed.resourceReservation ?? existing.resourceReservation,
            resourcePoolClaim: streamed.resourcePoolClaim ?? existing.resourcePoolClaim,
            usesResourcePool: streamed.usesResourcePool,
            usage: streamed.usage,
            privateAddress: streamed.privateAddress,
            isPinned: streamed.isPinned
        )
        next.agentUpdates = streamed.agentUpdates ?? existing.agentUpdates
        return next
    }

    func applyVMChanges(upserts: [VMSummary], deletions: Set<String>, authoritative: Bool) {
        guard isCloudEnabled() else { return }
        streamChangesDuringRestRead?.append((upserts, deletions, authoritative))
        let previous = resourceStats?.snapshot ?? [:]
        var rows = machines
        var index = machineIndexByID
        var upsertedIDs = Set<String>()
        for summary in upserts {
            var snapshot = MachineSnapshotBuilder.snapshot(
                from: summary,
                freeAccessWindowDays: freeAccessWindowDays,
                previousStats: previous[summary.id]
            )
            snapshot.usage = usageByMachineID[summary.id]
            upsertedIDs.insert(summary.id)
            if let position = index[summary.id], rows.indices.contains(position), rows[position].id == summary.id {
                rows[position] = Self.keepingListOnlyFields(of: rows[position], in: snapshot, streamed: summary)
            } else {
                let createdAt = snapshot.createdAt ?? .distantPast
                let position = rows.firstIndex { ($0.createdAt ?? .distantPast) < createdAt } ?? rows.endIndex
                rows.insert(snapshot, at: position)
                index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            }
        }
        // Same as a list read: a streamed label that matches a pending rename
        // settles it; until then the pending label wins over the record's.
        reconcileOptimisticLabels(with: rows.filter { upsertedIDs.contains($0.id) })
        rows = applyingOptimisticLabels(to: rows)
        var removed = deletions
        if authoritative {
            removed.formUnion(rows.map(\.id).filter { !upsertedIDs.contains($0) })
        }
        if !removed.isEmpty {
            rows.removeAll { removed.contains($0.id) }
        }
        machineIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        machines = rows
        if authoritative {
            // A complete fleet prunes pins the same way a list read does; a
            // partial change only remembers order (readCatalog below).
            machinePinStore?.reconcile(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(rows, catalog: scopedCatalogSnapshot()).map(\.id))
            hasLoadedOnce = true
        }
        scheduleFreeAccessTransition()
        refreshStats()
        refreshUsage()
        readCatalog()
        plan = MachineSnapshotBuilder.planSnapshot(activeCount: rows.count, limits: lastLimits, machines: rows)
        #if DEBUG
        cmuxDebugLog("cloud.machines.list stream upserts=\(upserts.count) deletions=\(deletions.count) authoritative=\(authoritative) count=\(rows.count)")
        #endif
    }
}
