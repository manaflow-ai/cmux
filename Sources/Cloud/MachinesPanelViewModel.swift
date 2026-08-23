import Foundation
import SwiftUI

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
            isDesktop: summary.image.contains("xfce-vnc"),
            activity: activity(fromStatus: summary.status),
            createdAt: summary.createdAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000)
                : nil,
            label: summary.displayName
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

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
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
    }

    private func performRefresh() async {
        guard let client = VMClient.shared else {
            isLoading = false
            return
        }
        do {
            let page = try await client.listPage()
            let snapshots = page.vms.map(MachineSnapshotBuilder.snapshot(from:))
            machines = snapshots
            plan = MachineSnapshotBuilder.planSnapshot(activeCount: snapshots.count, limits: page.limits)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
