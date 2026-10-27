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
