import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHistory
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
    private var observation: Task<Void, Never>?
    private var deadlines: [String: DemandTimer] = [:]
    private var lastPrune: [String: ContinuousClock.Instant] = [:]
    private var limits = ClosedRetention(maxGroups: 0, maxAgeDays: 0)

    init(services: AppServices) {
        self.services = services
    }

    /// Starts applying the limits in `settings`.
    func start(settings: SettingsController) {
        guard let machines = services?.machines else { return }
        observation = Task { [weak self] in
            for await state in ObservationStream({ Self.state(settings: settings, daemons: machines.daemons) }) {
                self?.sync(state)
            }
        }
    }

    /// What a check depends on: the limits, and each connected daemon's
    /// closed history (count and oldest close).
    private struct SyncState: Sendable, Equatable {
        var limits: ClosedRetention
        var machines: [String: Summary]

        struct Summary: Sendable, Equatable {
            var count: Int
            var oldestMs: UInt64?
        }
    }

    private static func state(settings: SettingsController, daemons: [DaemonService]) -> SyncState {
        let setting = ClosedHistoryRetentionSetting(root: settings.snapshot.root)
        var machines: [String: SyncState.Summary] = [:]
        for daemon in daemons where daemon.store.servesStateResources {
            guard case .connected = daemon.store.connectionState else { continue }
            let items = daemon.store.closedItems
            machines[daemon.machineID] = SyncState.Summary(count: items.count, oldestMs: items.map(\.closedAtMs).min())
        }
        return SyncState(limits: ClosedRetention(maxGroups: setting.maxGroups, maxAgeDays: setting.maxAgeDays),
                         machines: machines)
    }

    private func sync(_ state: SyncState) {
        limits = state.limits
        lastPrune = lastPrune.filter { state.machines[$0.key] != nil }
        for (machine, timer) in deadlines where state.machines[machine] == nil {
            timer.cancel()
            deadlines[machine] = nil
        }
        check(Set(state.machines.keys))
    }

    private func check(_ machines: Set<String>) {
        let nowMs = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        for daemon in services?.machines.daemons ?? [] where machines.contains(daemon.machineID) {
            guard daemon.store.servesStateResources, case .connected = daemon.store.connectionState else { continue }
            let machine = daemon.machineID
            let items = daemon.store.closedItems
            let prune = limits.prune(items, nowMs: nowMs)
            let check = AppHistoryRules.ClosedCheck(
                overLimit: prune != nil, maxAgeDays: limits.maxAgeDays, oldestMs: items.map(\.closedAtMs).min(), nowMs: nowMs,
                count: items.count, closedLimit: SessionStateMirror.closedLimit, sinceLastPrune: lastPrune[machine].map { $0.duration(to: .now) })
            guard let decision = AppHistoryRules.closedCheck(check) else { continue }
            if let after = decision.recheckAfter {
                recheck(machine, after: after)
            } else if decision.cancelDeadline {
                deadlines[machine]?.cancel()
            }
            guard decision.prune, let prune else { continue }
            lastPrune[machine] = .now
            daemon.send("closed.delete", onFailure: { [weak self] _ in self?.recheck(machine, after: decision.retry) }) { connection in
                try await connection.state.pruneClosed(prune)
            }
        }
    }

    private func recheck(_ machine: String, after delay: Duration) {
        let timer = deadlines[machine] ?? DemandTimer(owner: "closed-retention")
        deadlines[machine] = timer
        timer.schedule(after: delay) { @MainActor [weak self] in self?.check([machine]) }
    }
}
