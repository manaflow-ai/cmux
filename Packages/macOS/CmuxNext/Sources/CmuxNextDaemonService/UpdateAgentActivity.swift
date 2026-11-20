public import CmuxNextAgentPane
public import CmuxUpdater
import Foundation

/// Keeps automatic updater relaunches away from Home Chief turns that are not present in the
/// daemon's workspace/tab mirror. The census is refreshed only while the relaunch gate asks for
/// it, so an idle app does not poll the agent daemon.
@MainActor
public final class UpdateAgentActivity {
    /// How long an answered census stands: the gate asks once a second and a read gets one
    /// second, so a census older than this means the reads stopped answering (a hung or failed
    /// read), and its facts are unknown, not the last answer.
    static let freshFor: Duration = .seconds(3)

    private let environment: AcpmuxEnvironment?
    private let clock: () -> ContinuousClock.Instant
    private var answer: (census: AcpmuxSessionCensus, at: ContinuousClock.Instant)?
    private var refreshedAt: ContinuousClock.Instant?
    private var refreshTask: Task<Void, Never>?

    /// Creates a census-backed relaunch safety coordinator.
    ///
    /// - Parameter environment: the local acpmux environment, or `nil` when no acpmux daemon is
    ///   available to protect.
    public convenience init(environment: AcpmuxEnvironment?) {
        self.init(environment: environment, clock: { ContinuousClock.now })
    }

    /// `clock`: a monotonic now (tests move it); a wall-clock step back must not keep an old census.
    init(environment: AcpmuxEnvironment?, clock: @escaping () -> ContinuousClock.Instant) {
        self.environment = environment
        self.clock = clock
    }

    /// The census answered within ``freshFor``, nil otherwise (none yet, the last read failed, or
    /// the reads stopped answering): Update When Idle reads its turns and drafts. With no acpmux,
    /// a known empty census. Refreshed, at most once a second, only by ``applying(to:)``.
    public var census: AcpmuxSessionCensus? {
        guard environment != nil else { return Self.noDaemonCensus }
        guard let answer, clock() - answer.at < Self.freshFor else { return nil }
        return answer.census
    }

    /// Adds Home Chief activity to a daemon relaunch snapshot, conservatively holding unknown state.
    ///
    /// - Parameter blockers: the tab and input blockers already collected by the daemon service.
    /// - Returns: the blockers with the Home Chief turn included when known.
    public func applying(to blockers: UpdateRelaunchBlockers) -> UpdateRelaunchBlockers {
        guard environment != nil else { return blockers }
        refreshIfNeeded()
        var result = blockers
        guard let census else {
            // Unknown is unsafe: a Home Chief turn could be running outside a tab.
            result.daemonStateUnavailable = true
            return result
        }
        if census.chiefInTurn { result.busyAgentCount += 1 }
        return result
    }

    /// Takes one read's answer (nil: it failed), stamped when it arrived.
    func record(_ census: AcpmuxSessionCensus?) {
        answer = census.map { ($0, clock()) }
    }

    private static var noDaemonCensus: AcpmuxSessionCensus {
        var census = AcpmuxSessionCensus()
        census.idleFactsKnown = true
        return census
    }

    private func refreshIfNeeded() {
        let now = clock()
        guard refreshTask == nil,
              refreshedAt.map({ now - $0 >= .seconds(1) }) ?? true else { return }
        refreshedAt = now
        let environment = environment
        refreshTask = Task { [weak self] in
            let census = await AcpmuxQuit.census(environment, deadline: .seconds(1), idleFacts: true)
            guard !Task.isCancelled else { return }
            self?.record(census)
            self?.refreshTask = nil
        }
    }
}
