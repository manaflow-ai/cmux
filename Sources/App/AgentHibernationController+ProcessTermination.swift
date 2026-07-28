import Darwin
import Foundation

extension AgentHibernationRecord {
    var processTerminationScope: AgentHibernationController.ProcessTerminationScope {
        AgentHibernationController.ProcessTerminationScope(
            key: key,
            processIDs: processIDs,
            processIdentities: processIdentities
        )
    }
}

extension AgentHibernationController {
    struct ProcessTerminationScope: Sendable {
        let key: AgentHibernationPanelKey
        let processIDs: Set<Int>
        let processIdentities: [Int: AgentPIDProcessIdentity]
    }

    struct ScopedProcessTermination: Equatable, Sendable {
        let processID: Int
        let processIdentity: AgentPIDProcessIdentity
        let processGroupID: pid_t
    }

    nonisolated static func processIdentities(
        for processIDs: Set<Int>
    ) -> [Int: AgentPIDProcessIdentity] {
        Dictionary(uniqueKeysWithValues: processIDs.compactMap { processID in
            guard processID > 0,
                  processID <= Int(Int32.max),
                  let identity = AgentPIDProcessIdentity(pid: pid_t(processID)) else {
                return nil
            }
            return (processID, identity)
        })
    }

    nonisolated static func scopedProcessTerminations(
        for scopes: [ProcessTerminationScope]
    ) async -> [AgentHibernationPanelKey: [ScopedProcessTermination]] {
        await withTaskGroup(
            of: (AgentHibernationPanelKey, [ScopedProcessTermination]?).self,
            returning: [AgentHibernationPanelKey: [ScopedProcessTermination]].self
        ) { group in
            var terminationsByPanel: [AgentHibernationPanelKey: [ScopedProcessTermination]] = Dictionary(
                uniqueKeysWithValues: scopes.compactMap { scope in
                    scope.processIDs.isEmpty ? (scope.key, []) : nil
                }
            )
            for scope in scopes where !scope.processIDs.isEmpty {
                group.addTask(priority: .utility) {
                    (
                        scope.key,
                        validatedScopedProcessTerminations(
                            for: scope,
                            processIdentityProvider: {
                                AgentPIDProcessIdentity(pid: pid_t($0))
                            },
                            processArgumentsProvider:
                                CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:),
                            processGroupProvider: { getpgid(pid_t($0)) }
                        )
                    )
                }
            }
            for await (key, terminations) in group {
                if let terminations {
                    terminationsByPanel[key] = terminations
                }
            }
            return terminationsByPanel
        }
    }

    nonisolated static func validatedScopedProcessTerminations(
        for scope: ProcessTerminationScope,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processGroupProvider: (Int) -> pid_t
    ) -> [ScopedProcessTermination]? {
        guard Set(scope.processIdentities.keys) == scope.processIDs else { return nil }
        var terminations: [ScopedProcessTermination] = []
        for processID in scope.processIDs.sorted(by: >) {
            guard processID > 0,
                  processID <= Int(Int32.max),
                  let expectedIdentity = scope.processIdentities[processID],
                  processIdentityProvider(processID) == expectedIdentity,
                  let process = processArgumentsProvider(processID),
                  process.matchesCMUXScope(
                      workspaceId: scope.key.workspaceId,
                      surfaceId: scope.key.panelId
                  ) else {
                return nil
            }
            terminations.append(
                ScopedProcessTermination(
                    processID: processID,
                    processIdentity: expectedIdentity,
                    processGroupID: processGroupProvider(processID)
                )
            )
        }
        return terminations
    }

    @discardableResult
    func terminateScopedProcessesForHibernation(
        _ terminations: [ScopedProcessTermination]
    ) -> Bool {
        guard !terminations.isEmpty else { return true }
        let currentProcessID = getpid()
        let currentProcessGroupID = getpgrp()
        guard terminations.allSatisfy({ termination in
            let pid = pid_t(termination.processID)
            return pid != currentProcessID &&
                AgentPIDProcessIdentity(pid: pid) == termination.processIdentity &&
                getpgid(pid) == termination.processGroupID
        }) else {
            return false
        }
        var signaledProcessGroups: Set<pid_t> = []
        for termination in terminations {
            let pid = pid_t(termination.processID)
            let processGroupID = termination.processGroupID
            if processGroupID > 1,
               processGroupID != currentProcessGroupID,
               signaledProcessGroups.insert(processGroupID).inserted {
                _ = kill(-processGroupID, SIGTERM)
            }
            _ = kill(pid, SIGTERM)
        }
        return true
    }
}
