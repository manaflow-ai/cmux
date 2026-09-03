import Foundation
import SwiftUI

extension Notification.Name {
    static let cmuxCloudVMAccessDidEnd = Notification.Name("cmux.cloudVM.accessDidEnd")
}

/// One machine row's immutable render state. Rows below the lazy-list boundary
/// receive only these snapshots plus a closure bundle (snapshot-boundary rule).
struct MachineSnapshot: Equatable, Identifiable {
    enum Activity: Equatable {
        /// Provisioned and reachable — wakes transparently on the next
        /// connection, so "running" and "asleep at $0" are the same green.
        case ready
        /// Still provisioning or waking.
        case pending
        /// Anything the backend reports that isn't a healthy machine.
        case attention(String)
    }

    /// Where a machine stands in the free plan's access window. The backend is
    /// the enforcement point (402 on access verbs); this mirrors it so the row
    /// can show the countdown and route a locked machine to the upgrade flow
    /// instead of a doomed connect.
    enum FreeAccessState: Equatable {
        /// Paid plan, or the window is disabled server-side.
        case unrestricted
        /// Reachable, with this many whole-or-partial days remaining.
        case active(daysLeft: Int)
        /// Past the window: preserved but locked until the plan is upgraded.
        case expired
    }

    let id: String
    let provider: String
    let image: String
    let isDesktop: Bool
    /// Verbs the provider can honor; menus omit Checkpoint/Fork when unsupported.
    var capabilities: VMCapabilities = .all
    let activity: Activity
    let createdAt: Date?
    /// User-chosen label; nil when the machine has no label.
    let label: String?
    /// Free-plan access window position; `.unrestricted` on paid plans.
    var freeAccess: FreeAccessState = .unrestricted
    /// Latest activity reading; nil until the first sample lands.
    var stats: VMStats?
    /// Coderouter spend over the usage window; nil until the team usage
    /// payload names this machine (and nil forever on backends without it).
    var usage: MachineUsageSnapshot?
    /// The machine's address on its owner's private network; nil for machines
    /// created before private networking. v4 preferred for copy (pasteable
    /// anywhere), v6 is the fallback.
    var privateAddress: String?

    var displayName: String { label?.isEmpty == false ? label! : id }

    var kindLabel: String {
        isDesktop
            ? String(localized: "machines.kind.desktop", defaultValue: "Desktop")
            : String(localized: "machines.kind.base", defaultValue: "Base")
    }

    var activityLabel: String {
        switch activity {
        case .ready:
            return String(localized: "machines.activity.ready", defaultValue: "Ready")
        case .pending:
            return String(localized: "machines.activity.pending", defaultValue: "Starting")
        case .attention(let status):
            return status
        }
    }
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
        case "pro", "team", "founders":
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

enum MachineSnapshotBuilder {
    static func snapshot(
        from summary: VMSummary,
        freeAccessWindowDays: Int = 0,
        now: Date = Date()
    ) -> MachineSnapshot {
        let createdAt = summary.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000)
            : nil
        // The backend's expiry wins when it sends one; the local window math is
        // the fallback for older control planes.
        let freeAccess = summary.freeAccessExpiresAt.map { expiresAt in
            freeAccessState(expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000), now: now)
        } ?? freeAccessState(createdAt: createdAt, windowDays: freeAccessWindowDays, now: now)
        return MachineSnapshot(
            id: summary.id,
            provider: summary.provider,
            image: summary.image,
            isDesktop: summary.resolvedKind.hasDesktop,
            capabilities: summary.capabilities,
            activity: activity(fromStatus: summary.status),
            createdAt: createdAt,
            label: summary.displayName,
            freeAccess: freeAccess,
            stats: nil,
            privateAddress: summary.preferredPrivateAddress
        )
    }

    /// Row state from a known expiry instant.
    static func freeAccessState(expiresAt: Date, now: Date = Date()) -> MachineSnapshot.FreeAccessState {
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return .active(daysLeft: Int((remaining / 86_400).rounded(.up)))
    }

    /// "6d 23h" while more than a day remains, "5h 12m" under a day, "1m" at
    /// the floor. Whole units, truncated: a countdown must never overstate.
    static func freeAccessCountdown(remaining: TimeInterval) -> String {
        let total = max(Int(remaining), 60)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return String(
                format: String(localized: "machines.freeAccess.countdown.daysHours", defaultValue: "%1$dd %2$dh"),
                days, hours
            )
        }
        if hours > 0 {
            return String(
                format: String(localized: "machines.freeAccess.countdown.hoursMinutes", defaultValue: "%1$dh %2$dm"),
                hours, minutes
            )
        }
        return String(
            format: String(localized: "machines.freeAccess.countdown.minutes", defaultValue: "%dm"),
            max(minutes, 1)
        )
    }

    /// Header banner for the fleet's earliest expiry. Paid plans never see one.
    static func freeAccessBanner(
        expiresAt: Date?,
        isPaidPlan: Bool,
        now: Date = Date()
    ) -> MachinePlanSnapshot.FreeAccessBanner {
        guard !isPaidPlan, let expiresAt else { return .none }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        let countdown = freeAccessCountdown(remaining: remaining)
        return remaining < 86_400 ? .expiresToday(countdown: countdown) : .expiresIn(countdown: countdown)
    }

    /// The fleet's earliest free-access expiry: the server's figure when it
    /// sends one, else the earliest `createdAt + window` across the machines.
    static func earliestFreeAccessExpiry(
        limits: VMPlanLimits,
        machines: [MachineSnapshot]
    ) -> Date? {
        if let serverMs = limits.freeAccessExpiresAt {
            return Date(timeIntervalSince1970: TimeInterval(serverMs) / 1000)
        }
        guard limits.freeAccessWindowDays > 0 else { return nil }
        return machines
            .compactMap { $0.createdAt?.addingTimeInterval(TimeInterval(limits.freeAccessWindowDays) * 86_400) }
            .min()
    }

    /// Mirrors the backend's window math (created + windowDays vs now); the
    /// backend stays the enforcement point, this only drives the row UI.
    static func freeAccessState(
        createdAt: Date?,
        windowDays: Int,
        now: Date = Date()
    ) -> MachineSnapshot.FreeAccessState {
        guard windowDays > 0, let createdAt else { return .unrestricted }
        let remaining = createdAt.addingTimeInterval(TimeInterval(windowDays) * 86_400).timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return .active(daysLeft: Int((remaining / 86_400).rounded(.up)))
    }

    /// The next instant at which a machine's free-access presentation changes:
    /// each day-boundary where the "N days left" label decrements, and finally
    /// the expiry itself. Nil once expired (or when no window applies) — there
    /// is nothing left to wait for. Expiry is a *known future timestamp*, so
    /// the panel arms a one-shot timer at exactly this instant instead of
    /// discovering the transition on a poll sweep.
    static func nextFreeAccessTransition(
        createdAt: Date?,
        windowDays: Int,
        now: Date = Date()
    ) -> Date? {
        guard windowDays > 0, let createdAt else { return nil }
        let expiry = createdAt.addingTimeInterval(TimeInterval(windowDays) * 86_400)
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let daysLeft = Int((remaining / 86_400).rounded(.up))
        // The label decrements when remaining crosses (daysLeft - 1) whole days;
        // for the final day that crossing IS the expiry.
        return expiry.addingTimeInterval(-TimeInterval(daysLeft - 1) * 86_400)
    }

    /// Stamps each snapshot with its usage readout, keyed by the machine id
    /// (`GET /api/vm` `id`, which the usage payload echoes as `vmId`). Machines
    /// the payload does not name lose any earlier readout so a machine that
    /// dropped out of the window never keeps a stale number.
    static func applyingUsage(
        to snapshots: [MachineSnapshot],
        usage: [String: MachineUsageSnapshot]
    ) -> [MachineSnapshot] {
        snapshots.map { snapshot in
            var next = snapshot
            next.usage = usage[snapshot.id]
            return next
        }
    }

    /// Recomputes only the free-access facet of existing snapshots against a
    /// fresh clock — no network, stats and identity preserved.
    static func applyingFreeAccess(
        to snapshots: [MachineSnapshot],
        windowDays: Int,
        now: Date = Date()
    ) -> [MachineSnapshot] {
        snapshots.map { snapshot in
            var next = snapshot
            next.freeAccess = freeAccessState(createdAt: snapshot.createdAt, windowDays: windowDays, now: now)
            return next
        }
    }

    static func activity(fromStatus status: String) -> MachineSnapshot.Activity {
        switch status.lowercased() {
        case "running", "ready", "standby", "paused":
            return .ready
        case "creating", "starting", "pending", "resuming":
            return .pending
        default:
            return .attention(status)
        }
    }

    static func planSnapshot(
        activeCount: Int,
        limits: VMPlanLimits?,
        machines: [MachineSnapshot] = [],
        now: Date = Date()
    ) -> MachinePlanSnapshot? {
        guard let limits else { return nil }
        let isPaidPlan = MachinePlanSnapshot.isPaidPlanID(limits.planId)
        let expiresAt = isPaidPlan ? nil : earliestFreeAccessExpiry(limits: limits, machines: machines)
        return MachinePlanSnapshot(
            activeCount: activeCount,
            maxActiveVms: limits.maxActiveVms,
            planId: limits.planId,
            freeAccessWindowDays: limits.freeAccessWindowDays,
            freeAccessExpiresAt: expiresAt,
            freeAccessBanner: freeAccessBanner(expiresAt: expiresAt, isPaidPlan: isPaidPlan, now: now)
        )
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
        case .notSignedIn, .sessionRefreshFailed, .backendUnreachable, .httpStatus, .malformedResponse:
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
    /// Last failure from a tree verb (open, new terminal, …); shown in the
    /// control bar's help text, cleared by the next successful refresh.
    @Published private(set) var treeErrorDescription: String?
    /// Creates in flight or failed, mirrored from ``createCoordinator`` so the
    /// tree renders them as pending machine rows above the fleet. The
    /// coordinator outlives this panel: a create started from one window shows
    /// in every Machines panel and survives the panel closing.
    @Published private(set) var pendingCreates: [MachineCreateOperation] = []
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
    /// One-shot timer armed at the exact next free-access transition (a
    /// countdown day-boundary or an expiry). Expiry is client-computable from
    /// createdAt + window, so rows flip at the boundary itself — scheduling,
    /// not polling; the slow poll only covers changes made elsewhere.
    private var freeAccessTransitionTask: Task<Void, Never>?
    private var freeAccessWindowDays = 0
    /// Last plan limits the list returned; the banner countdown re-derives from
    /// these on every local recompute without another round trip.
    private var lastLimits: VMPlanLimits?
    /// Which image each kind provisions, from the last list; empty until then.
    var imageKinds: [VMImageKindOption] { lastLimits?.imageKinds ?? [] }
    private var authSignOutObserver: NSObjectProtocol?
    private var treeChangeObserver: NSObjectProtocol?
    private var createChangeObserver: NSObjectProtocol?
    private var treeTask: Task<Void, Never>?
    private static let statsInterval: Duration = .seconds(20)

    init(createCoordinator: MachineCreateCoordinator = .shared) {
        self.createCoordinator = createCoordinator
        pendingCreates = createCoordinator.operations
        createChangeObserver = NotificationCenter.default.addObserver(
            forName: MachineCreateCoordinator.didChangeNotification,
            object: createCoordinator,
            queue: .main
        ) { [weak self] notification in
            let finished = notification.userInfo?[MachineCreateCoordinator.finishedUserInfoKey] as? MachineCreateCoordinator.Finished
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
        // The catalog posts on every resource/projection change (link state,
        // terminals, panes opening or closing); re-read its snapshot instead of
        // waiting for the slow poll.
        treeChangeObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (`queue: .main`), which is the main actor.
            MainActor.assumeIsolated { self?.scheduleCatalogRead() }
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
        if let authSignOutObserver {
            NotificationCenter.default.removeObserver(authSignOutObserver)
        }
        if let treeChangeObserver {
            NotificationCenter.default.removeObserver(treeChangeObserver)
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
        pendingCreates = createCoordinator.operations
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
        catalog = SurfaceCatalog.shared.snapshot
        localWorkspaces = localWorkspacesProvider()
    }

    /// The explicit Refresh verb: asks every provider to re-sync (machine list,
    /// links, local panels), then re-reads the catalog.
    func refreshTree(force: Bool) {
        treeTask?.cancel()
        treeTask = Task { [weak self] in
            if force {
                await SurfaceCatalog.shared.refreshAll()
            }
            guard !Task.isCancelled, let self else { return }
            self.readCatalog()
            self.treeErrorDescription = nil
        }
    }

    /// `refresh(tree: true)` is the explicit Refresh verb: machines, stats, and a
    /// forced catalog re-sync.
    func refresh(tree forceTree: Bool) {
        refresh()
        refreshTree(force: forceTree)
    }

    /// Samples every machine's CPU/memory/disk. Sleeping machines report
    /// `asleep` without being woken, so polling never costs the user anything.
    func refreshStats() {
        statsTask?.cancel()
        let ids = machines.map(\.id)
        guard !ids.isEmpty else { return }
        statsTask = Task { [weak self] in
            await withTaskGroup(of: (String, VMStats?).self) { group in
                for id in ids {
                    group.addTask {
                        (id, try? await VMClient.shared.stats(id: id))
                    }
                }
                for await (id, stats) in group {
                    guard !Task.isCancelled, let stats else { continue }
                    await MainActor.run { [weak self] in
                        guard let self, let index = self.machines.firstIndex(where: { $0.id == id }) else { return }
                        self.machines[index].stats = stats
                    }
                }
            }
        }
    }
    /// Fetches the team's per-machine coderouter spend and stamps it onto the
    /// rows. Rides the machine-list refresh, so it shares that cadence. Any
    /// failure (404 on a backend without the route, network) is "no data":
    /// nothing is surfaced, and the previous readout stays until a fetch
    /// succeeds. An `unavailable` payload clears it.
    func refreshUsage() {
        usageTask?.cancel()
        guard let client = MachineUsageClient.shared else { return }
        usageTask = Task { [weak self] in
            guard let usage = try? await client.teamUsage() else { return }
            guard !Task.isCancelled, let self else { return }
            self.applyUsage(usage.byMachineID)
        }
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

    func refresh() {
        guard refreshTask == nil else {
            refreshRequestedWhileLoading = true
            return
        }
        isLoading = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshRequestedWhileLoading {
                self.refreshRequestedWhileLoading = false
                self.refresh()
            }
        }
    }

    func startPolling() {
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
        pollTask?.cancel()
        pollTask = nil
        statsTask?.cancel()
        statsTask = nil
        usageTask?.cancel()
        usageTask = nil
        treeTask?.cancel()
        treeTask = nil
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
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileLoading = false
        statsTask?.cancel()
        statsTask = nil
        usageTask?.cancel()
        usageTask = nil
        freeAccessTransitionTask?.cancel()
        freeAccessTransitionTask = nil
        treeTask?.cancel()
        treeTask = nil
        freeAccessWindowDays = 0
        lastLimits = nil
        machines = []
        usageByMachineID = [:]
        catalog = .empty
        localWorkspaces = []
        treeErrorDescription = nil
        plan = nil
        activeOperation = nil
        pendingCreates = []
        lastErrorDescription = nil
        listProblem = nil
        hasLoadedOnce = false
        isLoading = false
    }

    private func performRefresh() async {
        guard let client = VMClient.shared else {
            isLoading = false
            return
        }
        do {
            let page = try await client.listPage()
            let previous = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.stats) })
            let freeAccessWindowDays = page.limits?.freeAccessWindowDays ?? 0
            self.freeAccessWindowDays = freeAccessWindowDays
            var snapshots = page.vms.map {
                MachineSnapshotBuilder.snapshot(from: $0, freeAccessWindowDays: freeAccessWindowDays)
            }
            for index in snapshots.indices {
                snapshots[index].stats = previous[snapshots[index].id] ?? nil
            }
            snapshots = MachineSnapshotBuilder.applyingUsage(to: snapshots, usage: usageByMachineID)
            machines = snapshots
            lastLimits = page.limits
            scheduleFreeAccessTransition()
            refreshStats()
            refreshUsage()
            readCatalog()
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: snapshots.count, limits: page.limits, machines: snapshots)
            lastErrorDescription = nil
            listProblem = nil
        } catch let error as VMClientError {
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
            lastErrorDescription = String(describing: error)
            listProblem = .unreachable
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
