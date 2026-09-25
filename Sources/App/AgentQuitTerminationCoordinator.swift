import Foundation

/// Terminates the agent processes cmux spawned and waits for their exact
/// process generations to exit before the app replies to a quit request.
///
/// cmux owns the agents it launched. Until this coordinator existed, quit left
/// them to the SIGHUP that the closing pty delivers as the process dies, and
/// never waited. Codex treats that SIGHUP as a graceful-only shutdown and keeps
/// its thread writer lock (`$CODEX_HOME/thread-writer-locks/<thread>.lock`)
/// until it finishes, so a relaunched cmux could run `codex resume` against a
/// lock that the previous agent still held and open the thread read-only
/// (https://github.com/manaflow-ai/cmux/issues/12805).
///
/// The signal path is the hibernation teardown's: exact PID-generation, process
/// group, controlling-TTY, and cmux-scope validation before SIGTERM, then a
/// bounded wait, validated SIGKILL escalation for survivors, and a bounded
/// post-kill wait. If the refresh cannot prove the target group, the process is
/// left alone rather than signaling stale process-group data.
struct AgentQuitTerminationCoordinator: Sendable {
    struct Outcome: Equatable, Sendable {
        /// Panels whose recorded agent processes were live and validated.
        var targetPanels = 0
        /// Panels whose processes exited (by SIGTERM, SIGKILL, or on their own).
        var exitedPanels = 0
        /// Panels whose process evidence failed exact validation and were left alone.
        var rejectedPanels = 0
        /// Panels whose processes were signalled but did not exit within the budget.
        var survivingPanels = 0
    }

    /// Time allowed for a SIGTERM'd agent to exit before SIGKILL.
    let gracePeriod: Duration
    /// Time allowed after SIGKILL for the kernel to reap the generation.
    let postKillExitPeriod: Duration

    /// Codex handles SIGTERM as a forceable shutdown and exits well within a
    /// second; the grace period leaves room for a busy agent to flush state.
    init(
        gracePeriod: Duration = .milliseconds(2_500),
        postKillExitPeriod: Duration = .seconds(1)
    ) {
        self.gracePeriod = gracePeriod
        self.postKillExitPeriod = postKillExitPeriod
    }

    /// Upper bound on the time `terminateAndWait` spends for any number of panels
    /// (panels are terminated concurrently).
    var budget: Duration {
        gracePeriod + postKillExitPeriod
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func terminateAndWait(
        scopes: [AgentHibernationController.ProcessTerminationScope]
    ) async -> Outcome {
        let liveScopes = scopes.filter { !$0.processIDs.isEmpty }
        var outcome = Outcome()
        guard !liveScopes.isEmpty else { return outcome }

        let terminationsByPanel = await AgentHibernationController
            .scopedProcessTerminations(for: liveScopes)
        let snapshotCoordinator = AgentHibernationProcessSnapshotCoordinator()
        let gracePeriod = gracePeriod
        let postKillExitPeriod = postKillExitPeriod

        // Exact-generation validation failed for at least one recorded PID of
        // a panel that is absent here; that whole panel stays untouched.
        let validatedScopes = liveScopes.filter { terminationsByPanel[$0.key] != nil }
        outcome.rejectedPanels = liveScopes.count - validatedScopes.count
        outcome.targetPanels = validatedScopes.count

        let results = await withTaskGroup(of: PanelResult.self) { group in
            for scope in validatedScopes {
                guard let terminations = terminationsByPanel[scope.key] else { continue }
                group.addTask(priority: .userInitiated) {
                    await Self.terminatePanel(
                        terminations,
                        processScopeKey: scope.key,
                        gracePeriod: gracePeriod,
                        postKillExitPeriod: postKillExitPeriod,
                        snapshotCoordinator: snapshotCoordinator
                    )
                }
            }
            var results: [PanelResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for result in results {
            switch result {
            case .exited:
                outcome.exitedPanels += 1
            case .rejected:
                outcome.rejectedPanels += 1
            case .survived:
                outcome.survivingPanels += 1
            }
        }
        return outcome
    }

    private enum PanelResult: Sendable {
        case exited
        case rejected
        case survived
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated static func terminatePanel(
        _ terminations: [AgentHibernationController.ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey,
        gracePeriod: Duration,
        postKillExitPeriod: Duration,
        snapshotCoordinator: AgentHibernationProcessSnapshotCoordinator
    ) async -> PanelResult {
        guard !terminations.isEmpty else { return .exited }
        let signalled = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                terminations,
                processScopeKey: processScopeKey
            )
        switch signalled {
        case .rejected:
            return .rejected
        case .exited:
            return .exited
        case .committedAwaitingExit:
            break
        }
        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitAfterEscalation(
                terminations,
                processScopeKey: processScopeKey,
                gracePeriod: gracePeriod,
                postKillExitPeriod: postKillExitPeriod,
                nextEpochProvider: { leaders, scopeKey, ttyDevice, exited in
                    await snapshotCoordinator.refreshedExitEpoch(
                        processGroupLeaders: leaders,
                        processScopeKey: scopeKey,
                        ttyDevice: ttyDevice,
                        excluding: exited
                    )
                }
            )
        if didExit { return .exited }
        // The shared hibernation waiter owns escalation. If its authoritative
        // process-group refresh cannot prove a safe SIGKILL target, leave the
        // generation alone rather than signaling a reused group from stale data.
        let alive = terminations.contains {
            AgentPIDProcessIdentity(pid: pid_t($0.processID)) == $0.processIdentity
        }
        return alive ? .survived : .exited
    }
}
