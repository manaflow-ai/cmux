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
    let activity: Activity
    let createdAt: Date?
    /// User-chosen label; nil when the machine has no label.
    let label: String?
    /// Free-plan access window position; `.unrestricted` on paid plans.
    var freeAccess: FreeAccessState = .unrestricted
    /// Latest activity reading; nil until the first sample lands.
    var stats: VMStats?

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

/// Plan meter shown in the panel header: "2 of 3 machines".
struct MachinePlanSnapshot: Equatable {
    let activeCount: Int
    let maxActiveVms: Int
    let planId: String

    var isAtLimit: Bool { activeCount >= maxActiveVms }
    var isPaidPlan: Bool { planId != "free" }
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
        return MachineSnapshot(
            id: summary.id,
            provider: summary.provider,
            image: summary.image,
            isDesktop: summary.image.contains("xfce-vnc"),
            activity: activity(fromStatus: summary.status),
            createdAt: createdAt,
            label: summary.displayName,
            freeAccess: freeAccessState(createdAt: createdAt, windowDays: freeAccessWindowDays, now: now),
            stats: nil
        )
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

    static func planSnapshot(activeCount: Int, limits: VMPlanLimits?) -> MachinePlanSnapshot? {
        guard let limits else { return nil }
        return MachinePlanSnapshot(
            activeCount: activeCount,
            maxActiveVms: limits.maxActiveVms,
            planId: limits.planId
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
    /// Human-readable label of the Cloud VM action currently running from this
    /// panel ("Checkpointing noble-wren…"). Replaces the plan meter in the
    /// header while set — the in-app substitute for a floating progress HUD.
    @Published private(set) var activeOperation: String?

    func beginOperation(_ label: String) {
        activeOperation = label
    }

    func endOperation() {
        activeOperation = nil
        refresh()
    }

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    /// One-shot timer armed at the exact next free-access transition (a
    /// countdown day-boundary or an expiry). Expiry is client-computable from
    /// createdAt + window, so rows flip at the boundary itself — scheduling,
    /// not polling; the slow poll only covers changes made elsewhere.
    private var freeAccessTransitionTask: Task<Void, Never>?
    private var freeAccessWindowDays = 0
    private var authSignOutObserver: NSObjectProtocol?
    private static let statsInterval: Duration = .seconds(20)

    init() {
        authSignOutObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAuthTransition()
            }
        }
    }

    deinit {
        if let authSignOutObserver {
            NotificationCenter.default.removeObserver(authSignOutObserver)
        }
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
    private static let pollInterval: Duration = .seconds(45)

    func refresh() {
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
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
        statsTask?.cancel()
        statsTask = nil
        freeAccessTransitionTask?.cancel()
        freeAccessTransitionTask = nil
        freeAccessWindowDays = 0
        machines = []
        plan = nil
        activeOperation = nil
        lastErrorDescription = nil
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
            machines = snapshots
            scheduleFreeAccessTransition()
            refreshStats()
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: snapshots.count, limits: page.limits)
            lastErrorDescription = nil
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
                hasLoadedOnce = false
                isLoading = false
                return
            }
            lastErrorDescription = String(describing: error)
        } catch {
            lastErrorDescription = String(describing: error)
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
