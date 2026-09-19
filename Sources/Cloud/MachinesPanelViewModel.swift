import CmuxCloudMachines
import Foundation
import SwiftUI

extension Notification.Name {
    static let cmuxCloudVMAccessDidEnd = Notification.Name("cmux.cloudVM.accessDidEnd")
}

/// Plan meter shown in the panel header: "2 of 3 machines" / "1 of 1 machine".
struct MachinePlanSnapshot: Equatable {
    /// What the header says about the free plan's access window. Precomputed
    /// against a clock in the view model so no row or meter reads `Date()` in
    /// `body`; `.none` on paid plans and when nothing is on a window.
    enum FreeAccessBanner: Equatable {
        case none
        /// More than a day left; `countdown` reads like "6d 23h".
        case expiresIn(countdown: String)
        /// Under a day left; `countdown` reads like "5h 12m".
        case expiresToday(countdown: String)
        /// The window closed: machines are preserved but locked until upgrade.
        case expired
    }

    let activeCount: Int
    /// Active-machine ceiling; nil when the plan has no cap (every paid plan).
    let maxActiveVms: Int?
    let planId: String
    /// Days the plan keeps a machine reachable after creation; 0 = no window.
    var freeAccessWindowDays: Int = 0
    /// Earliest free-access expiry across the fleet (server value when present).
    var freeAccessExpiresAt: Date? = nil
    var freeAccessBanner: FreeAccessBanner = .none

    /// An uncapped plan is never at the limit.
    var isAtLimit: Bool {
        guard let maxActiveVms else { return false }
        return activeCount >= maxActiveVms
    }
    /// Only plans the backend accepts for provisioning are paid. Unknown plan
    /// ids fail closed here too, so a stale metadata value cannot hide the
    /// upgrade affordance after the server returns `vm_requires_pro`.
    var isPaidPlan: Bool { Self.isPaidPlanID(planId) }

    static func isPaidPlanID(_ planId: String) -> Bool {
        switch planId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "go", "pro", "max", "team", "founders":
            return true
        default:
            return false
        }
    }

    /// Single-machine plans (free) read "1 of 1 machine", never "machines".
    var isSingleMachinePlan: Bool { maxActiveVms == 1 }

    /// The header meter text, singular/plural chosen by the plan's ceiling.
    /// Uncapped plans read "3 machines": there is no "of N" to show.
    var countLabel: String {
        guard let maxActiveVms else {
            if activeCount == 1 {
                return String(localized: "machines.meter.count.unlimited.single", defaultValue: "1 machine")
            }
            let format = String(localized: "machines.meter.count.unlimited", defaultValue: "%1$d machines")
            return String(format: format, activeCount)
        }
        if isSingleMachinePlan {
            let format = String(localized: "machines.meter.count.single", defaultValue: "%1$d of 1 machine")
            return String(format: format, activeCount)
        }
        let format = String(localized: "machines.meter.count", defaultValue: "%1$d of %2$d machines")
        return String(format: format, activeCount, maxActiveVms)
    }

    /// The banner line under the header; nil when there is nothing to say.
    var freeAccessBannerText: String? {
        switch freeAccessBanner {
        case .none:
            return nil
        case .expiresIn(let countdown):
            return String(
                format: String(localized: "machines.freeAccess.expiresIn", defaultValue: "Free cloud access \u{00B7} expires in %@"),
                countdown
            )
        case .expiresToday(let countdown):
            return String(
                format: String(localized: "machines.freeAccess.expiresToday", defaultValue: "Free cloud access \u{00B7} expires today, %@ left"),
                countdown
            )
        case .expired:
            return String(localized: "machines.freeAccess.expired", defaultValue: "Free cloud access expired \u{00B7} Upgrade to Pro")
        }
    }
}


/// Loads the machine fleet for the right-sidebar Machines tab. Refreshes on
/// demand plus a slow poll while the panel is visible; machine mutations go
/// through the shared Cloud VM action path (`CloudVMActionLauncher`), never
/// through this store.
@MainActor
final class MachinesPanelViewModel: ObservableObject {
    @Published private(set) var machines: [MachineSnapshot] = []
    @Published private(set) var plan: MachinePlanSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var lastErrorDescription: String?
    /// Why the machine list could not load, classified so the empty state can
    /// say the true thing: a server-rejected session needs a fresh sign-in, a
    /// plan gate needs an upgrade, and only genuinely transient failures get
    /// the retry-first "unreachable" presentation.
    @Published private(set) var listProblem: CloudListProblem?
    /// Per-machine coderouter spend from the last successful usage fetch,
    /// keyed by machine id. Refreshed with every machine-list refresh (the
    /// slow poll and the explicit Refresh verb), never more often. Empty on
    /// backends without the usage route; a failed fetch keeps the last value.
    @Published private(set) var usageByMachineID: [String: MachineUsageSnapshot] = [:]

    enum CloudListProblem: Equatable {
        /// HTTP 401: the Cloud service no longer accepts this session.
        case sessionRejected
        /// HTTP 402: the plan gates Cloud access.
        case requiresPro
        /// Everything else — retrying may help.
        case unreachable
    }

    /// Classify a list failure for ``listProblem``. Pure so tests can pin the
    /// mapping without a live client.
    nonisolated static func classifyListFailure(_ error: VMClientError) -> CloudListProblem {
        switch error {
        case .httpStatus(401, _):
            return .sessionRejected
        case .httpStatus(402, _):
            return .requiresPro
        case .notSignedIn, .sessionRefreshFailed, .backendUnreachable, .httpStatus, .malformedResponse, .lifecycleUnsupported,
             .disabledByManagedPolicy, .cloudMachinesDisabled:
            // A managed policy can race a refresh; keep the generic unreachable state.
            return .unreachable
        }
    }
    /// Human-readable label of the Cloud VM action currently running from this
    /// panel ("Checkpointing noble-wren…"). Replaces the plan meter in the
    /// header while set — the in-app substitute for a floating progress HUD.
    @Published private(set) var activeOperation: String?
    /// The surface catalog as one value: machines (this Mac first), their
    /// terminals/screens/browsers, and which local panes project them.
    @Published private(set) var catalog: SurfaceCatalogSnapshot = .empty
    /// Local workspaces in sidebar order, so this Mac's terminals group under
    /// the workspace that shows them (titles resolved here, above the outline).
    @Published private(set) var localWorkspaces: [CloudTreeLocalWorkspace] = []
    /// Machine id to terminal ids with a notification this Mac has not read,
    /// from the per-machine notification syncs.
    @Published private(set) var unreadTerminalIDs: [String: Set<String>] = [:]
    private var unreadObserver: NSObjectProtocol?
    /// Last failure from a tree verb (open, new terminal, …); shown in the
    /// control bar's help text, cleared by the next successful refresh.
    @Published private(set) var treeErrorDescription: String?
    /// In-flight and failed creates appear above the fleet; the shared
    /// coordinator keeps them visible across panels and panel closure.
    var pendingCreates: [MachineCreateOperation] { createCoordinator.operations }

    func setDefaultMachine(id: String) {
        guard machines.contains(where: { $0.id == id }) else { return }
        defaultMachineStore?.machineID = id
        machines = machines.map { machine in
            var next = machine
            next.isDefault = machine.id == id
            return next
        }
    }
    let createCoordinator: MachineCreateCoordinator
    /// How the view model reads local workspaces; injectable for tests.
    var localWorkspacesProvider: @MainActor () -> [CloudTreeLocalWorkspace] = {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        let selected = tabManager.selectedTabId
        return tabManager.tabs.map { CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == selected) }
    }

    func beginOperation(_ label: String) {
        activeOperation = label
    }

    func endOperation() {
        activeOperation = nil
        refresh()
    }

    func noteTreeFailure(_ description: String) {
        treeErrorDescription = description
    }

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var usageFailureCount = 0
    private var usageRetryNotBefore: Date?
    /// One-shot timer armed at the exact next free-access transition (a
    /// countdown day-boundary or an expiry). Expiry is client-computable from
    /// createdAt + window, so rows flip at the boundary itself — scheduling,
    /// not polling; the slow poll only covers changes made elsewhere.
    private var freeAccessTransitionTask: Task<Void, Never>?
    private var freeAccessWindowDays = 0
    /// Last plan limits the list returned; the banner countdown re-derives from
    /// these on every local recompute without another round trip.
    private var lastLimits: VMPlanLimits?
    var memoryOptionsMb: [Int] { lastLimits?.memoryOptionsMb ?? [] }
    var lockedMemoryOptionsMb: [Int]? { lastLimits?.lockedMemoryOptionsMb }
    var memoryUpgradePlanId: String? { lastLimits?.memoryUpgradePlanId }
    var memoryUpgradePlansByMb: [String: String]? { lastLimits?.memoryUpgradePlansByMb }
    private var authSignOutObserver: NSObjectProtocol?
    private var featureFlagObserver: CloudFeatureAvailabilityObserver?
    private var wantsPolling = false
    private var treeChangeObserver: NSObjectProtocol?
    private var createChangeObserver: NSObjectProtocol?
    private var treeTask: Task<Void, Never>?
    private let machineRefreshes = CloudMachineRefreshCoordinator { await SurfaceCatalog.shared.refresh(machine: $0, force: true) }
    private static let statsInterval: Duration = .seconds(20)

    let defaultMachineStore: DefaultCloudMachineStore?
    /// Explicit machine pins and the stable fleet order; nil keeps fleet order.
    let machinePinStore: CloudMachinePinStore?
    private let catalogProvider: @MainActor () -> SurfaceCatalogSnapshot
    private var awaitingCatalogScope = false

    init(
        createCoordinator: MachineCreateCoordinator? = nil,
        defaultMachineStore: DefaultCloudMachineStore? = nil,
        machinePinStore: CloudMachinePinStore? = nil,
        catalogProvider: @escaping @MainActor () -> SurfaceCatalogSnapshot = { SurfaceCatalog.shared.snapshot }
    ) {
        self.defaultMachineStore = defaultMachineStore
        self.machinePinStore = machinePinStore
        self.catalogProvider = catalogProvider
        // `.shared` is main-actor-isolated, so it cannot be a default argument
        // (default values evaluate in a nonisolated context); resolve it here.
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
        authSignOutObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAuthTransition()
            }
        }
        featureFlagObserver = CloudFeatureAvailabilityObserver(
            isEnabled: { CloudMachinesFeature.isEnabled },
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
        if let authSignOutObserver {
            NotificationCenter.default.removeObserver(authSignOutObserver)
        }
        if let treeChangeObserver {
            NotificationCenter.default.removeObserver(treeChangeObserver)
        }
        if let unreadObserver {
            NotificationCenter.default.removeObserver(unreadObserver)
        }
        if let createChangeObserver {
            NotificationCenter.default.removeObserver(createChangeObserver)
        }
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
        refresh()
    }
    /// Publishes the catalog's current value and the local workspace list. Cheap
    /// (a value read), so every change notification may call it.
    func readCatalog() {
        catalog = scopedCatalogSnapshot()
        // Catalog discoveries join the remembered fleet order as they appear, so a
        // machine the list endpoint has not returned yet still has a stable slot.
        machinePinStore?.remember(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(machines, catalog: catalog).map(\.id))
        localWorkspaces = localWorkspacesProvider()
        // The unread index and the catalog change on the same accepted daemon
        // state, so a catalog read also refreshes it. Cheap: a dictionary read.
        readUnreadTerminalIDs()
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
        refresh()
        refreshTree(force: forceTree)
    }
    func refreshMachine(_ machine: SurfaceMachineID) { machineRefreshes.refresh(machine) }
    /// Samples machines advertising stats support. Sleeping machines report
    /// `asleep` without being woken, so polling never costs the user anything.
    /// Older servers omitting the flag retain the desktop-only polling policy
    /// through capability decoding; explicit support overrides that fallback.
    func refreshStats() {
        guard CloudMachinesFeature.isEnabled else { return }
        statsTask?.cancel()
        let ids = machines.filter { $0.capabilities.stats }.map(\.id)
        guard !ids.isEmpty else { return }
        statsTask = Task { [weak self] in
            await withTaskGroup(of: (String, VMStats?).self) { group in
                for id in ids {
                    group.addTask {
                        (id, (try? await VMClient.shared.stats(id: id)) ?? .unavailable())
                    }
                }
                for await (id, stats) in group {
                    guard !Task.isCancelled, let stats else { continue }
                    await MainActor.run { [weak self] in
                        guard let self, CloudMachinesFeature.isEnabled,
                              let index = self.machines.firstIndex(where: { $0.id == id }),
                              self.machines[index].capabilities.stats else { return }
                        self.machines[index].stats = stats
                    }
                }
            }
        }
    }
    func refreshUsage() {
        guard CloudMachinesFeature.isEnabled, usageTask == nil else { return }
        if let retryNotBefore = usageRetryNotBefore, retryNotBefore > Date() { return }
        guard let client = MachineUsageClient.shared else { return }
        usageTask = Task { [weak self] in
            defer { self?.usageTask = nil }
            do {
                let usage = (try await client.teamUsage()).byMachineID
                guard !Task.isCancelled, CloudMachinesFeature.isEnabled, let self else { return }
                self.usageFailureCount = 0; self.usageRetryNotBefore = nil
                self.applyUsage(usage)
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, let self else { return }
                self.usageFailureCount = min(self.usageFailureCount + 1, 4)
                self.usageRetryNotBefore = Date().addingTimeInterval(Self.usageBackoffDelay(failureCount: self.usageFailureCount))
            }
        }
    }
    nonisolated static func usageBackoffDelay(failureCount: Int) -> TimeInterval {
        [30, 30, 60, 120, 300][min(max(failureCount, 0), 4)]
    }
    /// The one place usage lands: the lookup and the row snapshots move together.
    func applyUsage(_ usage: [String: MachineUsageSnapshot]) {
        usageByMachineID = usage
        machines = MachineSnapshotBuilder.applyingUsage(to: machines, usage: usage)
    }
    private static let pollInterval: Duration = .seconds(45)
    /// A refresh asked for while one is in flight runs again afterwards: a
    /// create that lands mid-poll must still replace its pending row with the
    /// real machine now, not on the next 45 s sweep.
    private var refreshRequestedWhileLoading = false
    /// Invalidates refresh completions when the Cloud gate closes. A cancelled
    /// URLSession task may still resume on the main actor, so cancellation
    /// alone is not enough to prevent stale rows or follow-up work.
    private var refreshGeneration: UInt64 = 0
    func refresh() {
        guard CloudMachinesFeature.isEnabled else { return }
        guard refreshTask == nil else {
            refreshRequestedWhileLoading = true
            return
        }
        isLoading = true
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            guard generation == self.refreshGeneration else { return }
            self.refreshTask = nil
            if self.refreshRequestedWhileLoading {
                self.refreshRequestedWhileLoading = false
                self.refresh()
            }
        }
    }
    func startPolling() {
        wantsPolling = true
        guard CloudMachinesFeature.isEnabled else {
            pausePolling()
            return
        }
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stopPolling() {
        wantsPolling = false
        pausePolling()
    }

    private func pausePolling() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileLoading = false
        refreshGeneration &+= 1
        isLoading = false
        statsTask?.cancel()
        statsTask = nil
        usageTask?.cancel()
        usageTask = nil
        usageFailureCount = 0
        usageRetryNotBefore = nil
        treeTask?.cancel()
        treeTask = nil
        machineRefreshes.cancelAll()
        freeAccessTransitionTask?.cancel()
        freeAccessTransitionTask = nil
    }

    /// Sleeps until the earliest upcoming transition across the fleet, then
    /// recomputes the free-access facet locally and re-arms for the next one.
    private func scheduleFreeAccessTransition(now: Date = Date()) {
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
                activeCount: self.machines.count, limits: self.lastLimits, machines: self.machines, now: now
            )
            self.scheduleFreeAccessTransition(now: now)
        }
    }

    /// Drop every locally cached machine and in-flight sample when auth ends.
    /// This is intentionally callable by the panel as well as the sign-out
    /// notification observer so a signed-out panel can never render a stale
    /// fleet while SwiftUI is catching up with the auth projection.
    func resetForAuthTransition() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileLoading = false
        refreshGeneration &+= 1
        statsTask?.cancel()
        statsTask = nil
        usageTask?.cancel()
        usageTask = nil
        usageFailureCount = 0
        usageRetryNotBefore = nil
        freeAccessTransitionTask?.cancel()
        freeAccessTransitionTask = nil
        treeTask?.cancel()
        treeTask = nil
        machineRefreshes.cancelAll()
        freeAccessWindowDays = 0
        lastLimits = nil
        machines = []
        usageByMachineID = [:]
        catalog = .empty
        localWorkspaces = []
        treeErrorDescription = nil
        plan = nil
        activeOperation = nil
        createCoordinator.cancelAllForAuthTransition()
        lastErrorDescription = nil
        listProblem = nil
        hasLoadedOnce = false
        isLoading = false
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

    private func scopedCatalogSnapshot() -> SurfaceCatalogSnapshot {
        let snapshot = catalogProvider()
        guard awaitingCatalogScope else { return snapshot }
        let allowed = Set(machines.map { SurfaceMachineID.cloud($0.id) }).union([.local])
        return SurfaceCatalogSnapshot(machines: snapshot.machines.filter { allowed.contains($0.id) },
            resources: snapshot.resources.filter { allowed.contains($0.machine) },
            projections: snapshot.projections.filter { allowed.contains($0.resource.machine) })
    }

    private func performRefresh() async {
        guard CloudMachinesFeature.isEnabled else {
            isLoading = false
            return
        }
        guard let client = VMClient.shared else {
            isLoading = false
            return
        }
        let generation = refreshGeneration
        let scope = machinePinStore?.scopeIdentifier
        do {
            let page = try await client.listPage()
            try Task.checkCancellation()
            guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier,
                  CloudMachinesFeature.isEnabled else { return }
            let previous = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.stats) })
            let freeAccessWindowDays = page.limits?.freeAccessWindowDays ?? 0
            self.freeAccessWindowDays = freeAccessWindowDays
            var snapshots = page.vms.map {
                MachineSnapshotBuilder.snapshot(
                    from: $0,
                    freeAccessWindowDays: freeAccessWindowDays,
                    previousStats: previous[$0.id] ?? nil
                )
            }
            snapshots = MachineSnapshotBuilder.applyingUsage(to: snapshots, usage: usageByMachineID)
            let defaultMachineID = defaultMachineStore?.resolveMachineID(
                from: snapshots.map { CloudMachineDescriptor(id: $0.id, isDesktop: $0.isDesktop) },
                isComplete: true
            )
            snapshots = snapshots.map { snapshot in
                var next = snapshot
                next.isDefault = snapshot.id == defaultMachineID
                return next
            }
            // The authoritative fleet plus catalog-only rows is the complete
            // visible set: a pin whose machine is gone from both is pruned.
            machinePinStore?.reconcile(machineIDs: MachineSnapshotBuilder.includingCatalogMachines(snapshots, catalog: scopedCatalogSnapshot()).map(\.id))
            machines = snapshots
            lastLimits = page.limits
            scheduleFreeAccessTransition()
            refreshStats()
            refreshUsage()
            readCatalog()
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: snapshots.count, limits: page.limits, machines: snapshots)
            lastErrorDescription = nil
            listProblem = nil
        } catch is CancellationError {
            return
        } catch let error as VMClientError {
            guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier else { return }
            if case .notSignedIn = error {
                // A request can race sign-out before the auth observation or
                // notification arrives. Clear the authoritative-looking
                // snapshot immediately; signed-out users must never see the
                // previous account's machines during that race.
                machines = []
                plan = nil
                activeOperation = nil
                lastErrorDescription = nil
                listProblem = nil
                hasLoadedOnce = false
                isLoading = false
                return
            }
            lastErrorDescription = String(describing: error)
            listProblem = Self.classifyListFailure(error)
        } catch {
            guard generation == refreshGeneration, scope == machinePinStore?.scopeIdentifier else { return }
            lastErrorDescription = String(describing: error)
            listProblem = .unreachable
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
