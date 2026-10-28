import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Recently closed retention (reopen-closed.md S1b): keeps each connected
/// daemon's closed history within `history.closed.maxGroups` and
/// `history.closed.maxAgeDays`. The daemons store no limit, so this compares
/// each mirror with the limits whenever either changes, and sends
/// `closed.delete` when one is over: at most once a minute per machine. A
/// deadline per machine checks again when the minute is up, when its oldest
/// group passes `maxAgeDays`, an hour after a failed delete (an older daemon
/// refuses the fields), or hourly while its mirror is full (it then cannot
/// see the oldest groups); nothing wakes in between.
final class ClosedHistoryRetention {
    private weak var services: AppServices?
    private let scheduler: MainDeadlineScheduler
    private var observation: ServiceObservation<SyncState>?
    /// Each machine's recheck. `background`: nobody waits on a prune.
    private var deadlines: [String: MainDeadline] = [:]
    private var lastPrune: [String: ContinuousClock.Instant] = [:]
    /// The limits and each machine's closed list revision at its last check.
    private var checks = ClosedRetentionChecks()
    private var limits: ClosedRetention { checks.limits }
    private static let interval = Duration.seconds(60)
    private static let retry = Duration.seconds(3600)

    init(services: AppServices) {
        self.services = services
        scheduler = services.mainDeadlines
    }

    /// Starts applying the limits in `settings`. `background`: the daemons are pruned whether or not
    /// anything shows them.
    func start(settings: SettingsController) {
        guard let services else { return }
        let machines = services.machines
        observation = ServiceObservation(.background, owner: "ClosedHistoryRetention.state", on: services.mainWork) {
            Self.state(settings: settings, daemons: machines.daemons)
        } apply: { [weak self] state in
            self?.sync(state)
        }
    }

    /// What a check depends on: the limits, and each connected daemon's
    /// closed list revision (``SessionStateStore/closedRevision``), one
    /// number per machine: the observation never reads the lists.
    private struct SyncState: Sendable, Equatable {
        var limits: ClosedRetention
        var machines: [String: UInt64]
    }

    private static func state(settings: SettingsController, daemons: [DaemonService]) -> SyncState {
        let setting = ClosedHistoryRetentionSetting(root: settings.snapshot.root)
        var machines: [String: UInt64] = [:]
        for daemon in daemons where daemon.store.servesStateResources {
            guard case .connected = daemon.store.connectionState else { continue }
            machines[daemon.machineID] = daemon.store.session.closedRevision
        }
        return SyncState(limits: ClosedRetention(maxGroups: setting.maxGroups, maxAgeDays: setting.maxAgeDays),
                         machines: machines)
    }

    /// Checks the machines whose closed list changed, or every one when the limits did.
    private func sync(_ state: SyncState) {
        let machines = checks.advance(limits: state.limits, machines: state.machines)
        lastPrune = lastPrune.filter { state.machines[$0.key] != nil }
        for (machine, timer) in deadlines where state.machines[machine] == nil {
            timer.cancel()
            deadlines[machine] = nil
        }
        check(machines)
    }

    private func check(_ machines: Set<String>) {
        // wall-clock: compared with the daemon's closedAtMs, Unix ms.
        let nowMs = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        for daemon in services?.machines.daemons ?? [] where machines.contains(daemon.machineID) {
            guard daemon.store.servesStateResources, case .connected = daemon.store.connectionState else { continue }
            let machine = daemon.machineID
            let items = daemon.store.closedItems
            guard let prune = limits.prune(items, nowMs: nowMs) else {
                // Within the limits: check again when the oldest group gets too old.
                if limits.maxAgeDays > 0, let oldest = items.map(\.closedAtMs).min() {
                    let due = oldest &+ UInt64(limits.maxAgeDays) * 86_400_000
                    recheck(machine, after: .milliseconds(Int64(clamping: (due > nowMs ? due - nowMs : 0) &+ 1)))
                } else {
                    deadlines[machine]?.cancel()
                }
                continue
            }
            if let last = lastPrune[machine], last.duration(to: .now) < Self.interval {
                recheck(machine, after: Self.interval - last.duration(to: .now))
                continue
            }
            lastPrune[machine] = .now
            if limits.maxAgeDays > 0, items.count >= SessionStateMirror.closedLimit {
                recheck(machine, after: Self.retry)
            } else {
                deadlines[machine]?.cancel()
            }
            daemon.send("closed.delete", onFailure: { [weak self] _ in self?.recheck(machine, after: Self.retry) }) { connection in
                try await connection.state.pruneClosed(prune)
            }
        }
    }

    private func recheck(_ machine: String, after delay: Duration) {
        let timer = deadlines[machine] ?? MainDeadline(owner: "ClosedHistoryRetention.recheck", workClass: .background, scheduler: scheduler)
        deadlines[machine] = timer
        timer.schedule(after: delay) { [weak self] in self?.check([machine]) }
    }
}

// Deleting closed history for good (History's Remove, Clear History), beside its retention.
extension DaemonClosedHistory {
    /// A deleted `window` item of this app: its closed window lets its
    /// workspaces go (nothing could reopen them otherwise).
    fileprivate static func releaseWindow(of item: ClosedItem, daemon: DaemonService, services: AppServices) {
        guard item.kind == .window, daemon.isLocal, let recorded = item.window,
              let install = try? services.cloud.localDeviceID(), recorded.hasPrefix(install + "/") else { return }
        services.windows.releaseClosedWindow(id: String(recorded.dropFirst(install.count + 1)))
    }

    /// Sends the agent-home folders of deleted closed workspaces (the
    /// daemon moved them to `.trash-pending`, cx-gzh.9.2) to the Trash, off
    /// the main thread. At launch and after each delete or clear.
    static func emptyAgentHomeTrash() { AgentHome.emptyStandardTrashPendingInBackground() }

    /// Deletes `entry` for good on its daemon (History's Remove, Search
    /// Tabs' forget): it cannot be reopened any more.
    static func delete(_ entry: Entry, services: AppServices) {
        let daemon = entry.daemon, id = entry.item.id, isLocal = daemon.isLocal
        releaseWindow(of: entry.item, daemon: daemon, services: services)
        // The daemon's send path: the command runs on the connection and reports to a capturing caller.
        daemon.send("closed.delete") { connection in
            do {
                try await connection.state.deleteClosed(id)
            } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                // Already gone (a second Remove, or a reopen that ran first): the goal holds.
                return
            }
            if isLocal { AgentHome.emptyStandardTrashPendingInBackground() }
        }
    }

    /// ``delete(_:services:)`` that answers once the daemon deleted `entry`:
    /// nil, or why not (`debug.closed_forget` waits for it).
    static func deleteNow(_ entry: Entry, services: AppServices) async -> String? {
        let daemon = entry.daemon, id = entry.item.id
        releaseWindow(of: entry.item, daemon: daemon, services: services)
        guard let connection = daemon.connection else { return MiscHandlerStrings.daemonOffline }
        do {
            try await connection.state.deleteClosed(id)
            if daemon.isLocal { emptyAgentHomeTrash() }
            return nil
        } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
            // Already gone (a second Remove, or a reopen that ran first): the goal holds.
            return nil
        } catch {
            daemon.logger.error("closed.delete failed: \(String(describing: error), privacy: .public)")
            return "closed.delete: \(error)"
        }
    }

    /// Clears every connected daemon's closed history: the groups closed at
    /// or after `since`, every group for nil (Clear History). `since` is this
    /// Mac's clock; a remote daemon with a skewed clock clears a range off by
    /// that skew.
    static func clear(since: Date?, services: AppServices) {
        let sinceMs = since.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) }
        for entry in entries([.window], in: services) where sinceMs.map({ entry.item.closedAtMs >= $0 }) ?? true {
            releaseWindow(of: entry.item, daemon: entry.daemon, services: services)
        }
        for daemon in services.machines.daemons where daemon.store.servesStateResources {
            let isLocal = daemon.isLocal
            daemon.send("closed.delete all") { connection in
                try await connection.state.deleteAllClosed(sinceMs: sinceMs)
                if isLocal { AgentHome.emptyStandardTrashPendingInBackground() }
            }
        }
    }
}
