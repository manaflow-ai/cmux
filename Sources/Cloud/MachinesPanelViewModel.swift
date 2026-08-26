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

/// One terminal session row inside an expanded machine: the machine's daemon
/// PTYs as last recorded by cmux Cloud (`cloud_vm_sessions`). Control-plane
/// state, not a live daemon probe — rows can lag a daemon restart, and the UI
/// says so.
struct MachineSessionSnapshot: Equatable, Identifiable {
    let id: String
    /// Daemon session id — the attach key for `cmux vm shell <vm> --session <id>`.
    let sessionId: String
    let title: String?
    let status: String
    let attachmentCount: Int
    let scrollbackBytes: Int
    let createdAt: Date?

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return sessionId
    }

    var statusLabel: String {
        switch status.lowercased() {
        case "running":
            return String(localized: "machines.session.status.running", defaultValue: "Running")
        case "exited":
            return String(localized: "machines.session.status.exited", defaultValue: "Exited")
        default:
            return status
        }
    }

    /// "Running · 2 attached · 1.2 MB", dropping the pieces that say nothing
    /// (zero attachments, zero scrollback).
    var subtitle: String {
        var parts = [statusLabel]
        if attachmentCount > 0 {
            parts.append(String(
                format: String(localized: "machines.detail.session.attached", defaultValue: "%d attached"),
                attachmentCount
            ))
        }
        if scrollbackBytes > 0 {
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(scrollbackBytes)))
        }
        return parts.joined(separator: " · ")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()
}

/// A local workspace currently attached to the machine (via its
/// `managed_cloud_vm_id`), with enough identity for a focus jump.
struct MachineWorkspaceSnapshot: Equatable, Identifiable {
    let id: UUID
    let title: String
}

/// Everything an expanded machine row shows: its terminals, and the local
/// workspaces already attached to it. The desktop row needs no detail state —
/// `MachineSnapshot.isDesktop` already carries it.
struct MachineDetailSnapshot: Equatable {
    var isLoading = false
    var sessions: [MachineSessionSnapshot] = []
    var workspaces: [MachineWorkspaceSnapshot] = []
    var sessionsErrorDescription: String?
    /// True once a session fetch has completed (success or failure), so the
    /// empty state only shows after we actually asked the backend.
    var hasLoadedSessions = false
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

    static func sessionSnapshot(from session: VMCloudSession) -> MachineSessionSnapshot {
        MachineSessionSnapshot(
            id: session.id,
            sessionId: session.sessionId,
            title: session.title?.isEmpty == false ? session.title : nil,
            status: session.status,
            attachmentCount: session.attachmentCount,
            scrollbackBytes: session.scrollbackBytes,
            createdAt: isoDate(session.createdAt)
        )
    }

    static func isoDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
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
    /// Machine ids whose row is expanded to show terminals + workspaces.
    @Published private(set) var expandedMachineIds: Set<String> = []
    /// Detail state per machine id, populated on expand and refreshed with the
    /// fleet poll while expanded.
    @Published private(set) var machineDetails: [String: MachineDetailSnapshot] = [:]
    private var detailTasks: [String: Task<Void, Never>] = [:]

    func toggleExpansion(machineId: String) {
        if expandedMachineIds.contains(machineId) {
            expandedMachineIds.remove(machineId)
            detailTasks[machineId]?.cancel()
            detailTasks[machineId] = nil
        } else {
            expandedMachineIds.insert(machineId)
            refreshDetails(machineId: machineId)
        }
    }

    /// Loads (or reloads) an expanded machine's terminals and attached
    /// workspaces. Workspaces come from the local window state synchronously;
    /// sessions from the Cloud control plane (last-known rows).
    func refreshDetails(machineId: String) {
        var detail = machineDetails[machineId] ?? MachineDetailSnapshot()
        detail.workspaces = Self.attachedWorkspaces(machineId: machineId)
        detail.isLoading = true
        machineDetails[machineId] = detail
        detailTasks[machineId]?.cancel()
        guard let client = VMClient.shared else {
            detail.isLoading = false
            machineDetails[machineId] = detail
            return
        }
        detailTasks[machineId] = Task { [weak self] in
            var sessions: [MachineSessionSnapshot] = []
            var errorDescription: String?
            do {
                sessions = try await client.listSessions(id: machineId)
                    .map(MachineSnapshotBuilder.sessionSnapshot(from:))
            } catch {
                errorDescription = String(describing: error)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var detail = self.machineDetails[machineId] ?? MachineDetailSnapshot()
                detail.isLoading = false
                detail.hasLoadedSessions = true
                detail.sessionsErrorDescription = errorDescription
                if errorDescription == nil {
                    detail.sessions = sessions
                }
                detail.workspaces = Self.attachedWorkspaces(machineId: machineId)
                self.machineDetails[machineId] = detail
                self.detailTasks[machineId] = nil
            }
        }
    }

    private static func attachedWorkspaces(machineId: String) -> [MachineWorkspaceSnapshot] {
        (AppDelegate.shared?.workspacesAttached(toManagedCloudVMID: machineId) ?? [])
            .map { MachineWorkspaceSnapshot(id: $0.id, title: $0.title) }
    }

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
        cancelDetailTasks()
    }

    private func cancelDetailTasks() {
        for task in detailTasks.values {
            task.cancel()
        }
        detailTasks = [:]
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
        cancelDetailTasks()
        machines = []
        plan = nil
        activeOperation = nil
        lastErrorDescription = nil
        hasLoadedOnce = false
        isLoading = false
        expandedMachineIds = []
        machineDetails = [:]
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
            // Keep expanded details fresh alongside the fleet poll, and drop
            // state for machines that no longer exist.
            let liveIds = Set(snapshots.map(\.id))
            expandedMachineIds.formIntersection(liveIds)
            machineDetails = machineDetails.filter { liveIds.contains($0.key) }
            for machineId in expandedMachineIds {
                refreshDetails(machineId: machineId)
            }
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
                cancelDetailTasks()
                expandedMachineIds = []
                machineDetails = [:]
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
