public import CmuxNextAgentPane
public import CmuxNextCompat
public import CmuxUpdater
import Foundation

/// Keeps automatic updater relaunches away from Home Chief turns that are not present in the
/// daemon's workspace/tab mirror. The census is refreshed only while the relaunch gate asks for
/// it, so an idle app does not poll the agent daemon.
@MainActor
public final class UpdateAgentActivity {
    private let environment: AcpmuxEnvironment?
    /// The app's blocking-work lanes: the census probes acpmux's socket and locks there.
    private let runner: any MayBlockRunner
    private var chiefInTurn: Bool?
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?

    /// Creates a census-backed relaunch safety coordinator.
    ///
    /// - Parameters:
    ///   - environment: the local acpmux environment, or `nil` when no acpmux daemon is available to protect.
    ///   - runner: the app's blocking-work lanes (the census's file probes).
    public init(environment: AcpmuxEnvironment?, runner: any MayBlockRunner) {
        self.environment = environment
        self.runner = runner
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
        let environment = environment, runner = runner
        refreshTask = Task { [weak self] in
            let census = await AcpmuxQuit.census(environment, runner: runner, deadline: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.chiefInTurn = census?.chiefInTurn
            self?.refreshTask = nil
        }
    }
}
