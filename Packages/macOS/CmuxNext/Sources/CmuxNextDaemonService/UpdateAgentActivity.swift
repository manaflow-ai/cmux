public import CmuxNextAgentPane
public import CmuxNextWakeups
public import CmuxUpdater
import Foundation

/// Keeps automatic updater relaunches away from Home Chief turns that are not present in the
/// daemon's workspace/tab mirror. The census is refreshed only while the relaunch gate asks for
/// it, so an idle app does not poll the agent daemon.
@MainActor
public final class UpdateAgentActivity {
    private let environment: AcpmuxEnvironment?
    /// Where the census's answer is applied (one background task: nobody waits on the relaunch gate's read).
    private let mainWork: MainWorkScheduler
    private var chiefInTurn: Bool?
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?

    /// Creates a census-backed relaunch safety coordinator.
    ///
    /// - Parameters:
    ///   - environment: the local acpmux environment, or `nil` when no acpmux daemon is
    ///     available to protect.
    ///   - mainWork: the app's main-thread scheduler; the census runs off main and its answer is
    ///     one background task on it.
    public init(environment: AcpmuxEnvironment?, mainWork: MainWorkScheduler) {
        self.environment = environment
        self.mainWork = mainWork
        // No acpmux environment means this app has no Home Chief to protect.
        self.chiefInTurn = environment == nil ? false : nil
    }

    /// Adds Home Chief activity to a daemon relaunch snapshot, conservatively holding unknown state.
    ///
    /// - Parameter blockers: the tab and input blockers already collected by the daemon service.
    /// - Returns: the blockers with the Home Chief turn included when known.
    public func applying(to blockers: UpdateRelaunchBlockers) -> UpdateRelaunchBlockers {
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
        let environment = environment, mainWork = mainWork
        // task-owner: one census at a time (`refreshTask`); its read is bounded by its own deadline.
        // R-hop: the census runs off main; its answer is one background task.
        refreshTask = Task { @concurrent in
            let chiefInTurn = await AcpmuxQuit.census(environment, deadline: .seconds(1))?.chiefInTurn
            mainWork.postFromAnyThread(.background, owner: "UpdateAgentActivity.census") { [weak self] in
                self?.censusAnswered(chiefInTurn)
            }
        }
    }

    private func censusAnswered(_ chiefInTurn: Bool?) {
        self.chiefInTurn = chiefInTurn
        refreshTask = nil
    }
}
