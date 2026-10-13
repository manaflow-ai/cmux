import CmuxNextAgentPane
import CmuxUpdater
import Foundation

/// Keeps automatic updater relaunches away from Home Chief turns that are not present in the
/// daemon's workspace/tab mirror. The census is refreshed only while the relaunch gate asks for
/// it, so an idle app does not poll the agent daemon.
@MainActor
final class UpdateAgentActivity {
    private let environment: AcpmuxEnvironment?
    private var chiefInTurn: Bool?
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?

    init(environment: AcpmuxEnvironment?) {
        self.environment = environment
        // No acpmux environment means this app has no Home Chief to protect.
        self.chiefInTurn = environment == nil ? false : nil
    }

    func applying(to blockers: UpdateRelaunchBlockers) -> UpdateRelaunchBlockers {
        guard environment != nil else { return blockers }
        refreshIfNeeded()
        var result = blockers
        guard let chiefInTurn else {
            // Unknown is unsafe: a Home Chief turn could be running outside a tab.
            result.daemonStateUnavailable = true
            return result
        }
        if chiefInTurn { result.busyAgentCount += 1 }
        return result
    }

    private func refreshIfNeeded() {
        let now = Date()
        guard refreshTask == nil,
              refreshedAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        refreshedAt = now
        // Do not reuse a previous answer while a new socket census is in flight.
        chiefInTurn = nil
        let environment = environment
        refreshTask = Task { [weak self] in
            let census = await AcpmuxQuit.census(environment, deadline: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.chiefInTurn = census?.chiefInTurn
            self?.refreshTask = nil
        }
    }
}
