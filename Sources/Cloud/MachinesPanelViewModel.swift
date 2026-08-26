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

    let id: String
    let provider: String
    let image: String
    let isDesktop: Bool
    let activity: Activity
    let createdAt: Date?
    /// User-chosen label; nil when the machine has no label.
    let label: String?
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
    static func snapshot(from summary: VMSummary) -> MachineSnapshot {
        MachineSnapshot(
            id: summary.id,
            provider: summary.provider,
            image: summary.image,
            isDesktop: summary.image.contains("xfce-vnc") || summary.image.contains("cmux-devbox"),
            activity: activity(fromStatus: summary.status),
            createdAt: summary.createdAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000)
                : nil,
            label: summary.displayName,
            stats: nil
        )
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
            var snapshots = page.vms.map(MachineSnapshotBuilder.snapshot(from:))
            for index in snapshots.indices {
                snapshots[index].stats = previous[snapshots[index].id] ?? nil
            }
            machines = snapshots
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
