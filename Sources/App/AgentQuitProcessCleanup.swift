import Darwin
import Foundation

/// Bounded shutdown of proven local agent process trees after session persistence.
struct AgentQuitProcessCleanup: Sendable {
    /// Refuses inherited cmux environment from another app, orphan, or reused PID.
    nonisolated static func isDescendant(
        _ identity: AgentPIDProcessIdentity,
        of appPID: pid_t,
        snapshot: (pid_t) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)? = {
            AgentPIDProcessIdentity.processSnapshot(pid: $0)
        }
    ) -> Bool {
        guard let first = snapshot(identity.pid), first.identity == identity else { return false }
        var parent = first.parentPID
        var visited: Set<pid_t> = [identity.pid]
        for _ in 0..<64 {
            if parent == appPID { return true }
            guard parent > 1, visited.insert(parent).inserted,
                  let ancestor = snapshot(parent) else { return false }
            parent = ancestor.parentPID
        }
        return false
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func terminate(
        scopes: [AgentHibernationController.ProcessTerminationScope],
        shouldCommit: @escaping @MainActor @Sendable (AgentHibernationPanelKey) -> Bool
    ) async {
        let appPID = getpid()
        let coordinator = AgentHibernationProcessSnapshotCoordinator()
        let terminations = await AgentHibernationController.scopedProcessTerminations(for: scopes)
        await withTaskGroup(of: Void.self) { group in
            for (key, processes) in terminations where !processes.isEmpty {
                group.addTask {
                    guard !Task.isCancelled,
                          processes.allSatisfy({ Self.isDescendant($0.processIdentity, of: appPID) }) else { return }
                    let result = await AgentHibernationController.terminateScopedProcessesForHibernation(
                        processes,
                        processScopeKey: key,
                        shouldCommit: {
                            !Task.isCancelled && shouldCommit(key)
                                && processes.allSatisfy { Self.isDescendant($0.processIdentity, of: appPID) }
                        }
                    )
                    guard result == .committedAwaitingExit, !Task.isCancelled else { return }
                    // Reuse exact-generation, TTY and cmux-scope revalidation at
                    // escalation. An unproven group is never killed just to quit.
                    _ = await AgentHibernationController.waitForScopedProcessGenerationsToExitAfterEscalation(
                        processes,
                        processScopeKey: key,
                        gracePeriod: .seconds(5),
                        postKillExitPeriod: .seconds(1),
                        nextEpochProvider: { leaders, scope, tty, exited in
                            await coordinator.refreshedExitEpoch(
                                processGroupLeaders: leaders,
                                processScopeKey: scope,
                                ttyDevice: tty,
                                excluding: exited
                            )
                        }
                    )
                }
            }
        }
    }
}
