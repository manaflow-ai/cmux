import Darwin
import Foundation

extension AgentHibernationController {
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func terminateScopedProcessesForHibernation(
        _ terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey,
        shouldCommit: @escaping @MainActor @Sendable () -> Bool = { true },
        onTeardownCommit: @escaping @MainActor @Sendable () -> Void = {},
        currentProcessID: pid_t = getpid(),
        currentProcessGroupID: pid_t = getpgrp(),
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: @escaping @Sendable (pid_t) -> pid_t = { getpgid($0) },
        processArgumentsProvider: @escaping @Sendable (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processTTYDeviceProvider: @escaping @Sendable (pid_t) -> Int64? = {
            agentLiveProcessIdentity(pid: $0)?.ttyDevice
        },
        signalErrorProvider: @escaping @Sendable (pid_t, Int32) -> Int32? = {
            target, signal in
            kill(target, signal) == 0 ? nil : errno
        }
    ) async -> ScopedProcessTerminationResult {
        let processGroupLeaders = processGroupLeaders(in: terminations)
        guard processGroupLeaders.count ==
                Set(terminations.map(\.processGroupID)).filter({ $0 > 1 }).count else {
            return .rejected
        }
        return await terminateScopedProcessEpochForHibernation(
            .init(
                terminations: terminations,
                processGroupLeaders: processGroupLeaders,
                signalableProcessIdentities: Set(terminations.map(\.processIdentity))
            ),
            processScopeKey: processScopeKey,
            shouldCommit: shouldCommit,
            onTeardownCommit: onTeardownCommit,
            currentProcessID: currentProcessID,
            currentProcessGroupID: currentProcessGroupID,
            processIdentityProvider: processIdentityProvider,
            processGroupProvider: processGroupProvider,
            processArgumentsProvider: processArgumentsProvider,
            processTTYDeviceProvider: processTTYDeviceProvider,
            signalErrorProvider: signalErrorProvider
        )
    }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func terminateScopedProcessEpochForHibernation(
        _ epoch: AgentHibernationProcessExitEpoch,
        processScopeKey: AgentHibernationPanelKey,
        shouldCommit: @escaping @MainActor @Sendable () -> Bool = { true },
        onTeardownCommit: @escaping @MainActor @Sendable () -> Void = {},
        currentProcessID: pid_t = getpid(),
        currentProcessGroupID: pid_t = getpgrp(),
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: @escaping @Sendable (pid_t) -> pid_t = { getpgid($0) },
        processArgumentsProvider: @escaping @Sendable (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processTTYDeviceProvider: @escaping @Sendable (pid_t) -> Int64? = {
            agentLiveProcessIdentity(pid: $0)?.ttyDevice
        },
        signalErrorProvider: @escaping @Sendable (pid_t, Int32) -> Int32? = {
            target, signal in
            kill(target, signal) == 0 ? nil : errno
        }
    ) async -> ScopedProcessTerminationResult {
        let terminations = epoch.terminations
        guard !terminations.isEmpty else {
            return await MainActor.run {
                guard shouldCommit() else { return .rejected }
                onTeardownCommit()
                return .exited
            }
        }
        guard terminations.count <= maximumScopedProcessTerminationCount,
              commonTTYDevice(in: terminations) != nil else {
            return .rejected
        }

        let signalableTerminations = terminations.filter {
            epoch.signalableProcessIdentities.contains($0.processIdentity)
        }
        let signalableProcessGroupIDs = Set(
            signalableTerminations.map(\.processGroupID)
        )
        guard !signalableProcessGroupIDs.isEmpty,
              signalableProcessGroupIDs.allSatisfy({
                  $0 > 1 &&
                      $0 != currentProcessGroupID &&
                      epoch.processGroupLeaders[$0] != nil
              }),
              terminations.allSatisfy({ termination in
                  let processID = pid_t(termination.processID)
                  return processID != currentProcessID &&
                      processIdentityProvider(processID) ==
                        termination.processIdentity &&
                      processGroupProvider(processID) == termination.processGroupID
              }) else {
            return .rejected
        }

        guard terminations.allSatisfy({ termination in
                  guard let ttyDevice = termination.ttyDevice else {
                      return false
                  }
                  return processTTYDeviceProvider(
                      pid_t(termination.processID)
                  ) == ttyDevice
              }),
              terminations.allSatisfy({ termination in
                  processArgumentsProvider(termination.processID)?.matchesCMUXScope(
                      workspaceId: processScopeKey.workspaceId,
                      surfaceId: processScopeKey.panelId
                  ) == true
              }),
              terminations.allSatisfy({ termination in
                  let processID = pid_t(termination.processID)
                  return processIdentityProvider(processID) ==
                        termination.processIdentity &&
                      processGroupProvider(processID) == termination.processGroupID
              }) else {
            return .rejected
        }

        // The probes above can block, so they deliberately run off the main actor.
        // The mutable panel gate, minimal exact kernel trust recheck, signal batch,
        // and UI commit below are one synchronous main-actor boundary. The full
        // process snapshot and argv/environment probes remain off-main, while no
        // input/focus event or actor hop can interleave after the final decision.
        return await MainActor.run {
            guard terminations.allSatisfy({ termination in
                      let processID = pid_t(termination.processID)
                      guard let ttyDevice = termination.ttyDevice else {
                          return false
                      }
                      return processIdentityProvider(processID) ==
                            termination.processIdentity &&
                          processGroupProvider(processID) == termination.processGroupID &&
                          processTTYDeviceProvider(processID) == ttyDevice
                  }),
                  signalableProcessGroupIDs.allSatisfy({ processGroupID in
                      guard let expectedLeader =
                              epoch.processGroupLeaders[processGroupID] else {
                          return false
                      }
                      // A process group can outlive its leader. A reused leader
                      // PID, however, invalidates the original group authority.
                      let liveLeader = processIdentityProvider(processGroupID)
                      return liveLeader == nil || liveLeader == expectedLeader
                  }),
                  shouldCommit() else {
                return .rejected
            }

            var teardownIsCommitted = false
            for processGroupID in signalableProcessGroupIDs.sorted() {
                if let error = signalErrorProvider(-processGroupID, SIGTERM) {
                    if error != ESRCH, !teardownIsCommitted {
                        return .rejected
                    }
                } else {
                    teardownIsCommitted = true
                }
            }
            // Every target may have exited between validation and signaling.
            // That is still an irreversible commit: no authorized generation
            // remains, and exact-exit observation resolves the final state.
            onTeardownCommit()
            return .committedAwaitingExit
        }
    }
}
