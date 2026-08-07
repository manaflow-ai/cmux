import Darwin
import Foundation

extension AgentHibernationController {
    typealias ProcessExitEpochProvider = @Sendable (
        [pid_t: AgentPIDProcessIdentity],
        AgentHibernationPanelKey?,
        Int64?,
        Set<AgentPIDProcessIdentity>
    ) async -> AgentHibernationProcessExitEpoch?

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func waitForScopedProcessGenerationsToExitAfterEscalation(
        _ terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey? = nil,
        gracePeriod: Duration = .seconds(5),
        postKillExitPeriod: Duration = .seconds(5),
        waitForExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)? = nil,
        sleepUntilDeadline: @escaping @Sendable (Duration) async -> Bool = { duration in
            do {
                // Genuine termination deadline; cancellation aborts the wait.
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        },
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: @escaping @Sendable (pid_t) -> pid_t = {
            getpgid($0)
        },
        processArgumentsProvider: @escaping @Sendable (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processTTYDeviceProvider: @escaping @Sendable (pid_t) -> Int64? = {
            agentLiveProcessIdentity(pid: $0)?.ttyDevice
        },
        signalErrorProvider: @escaping @Sendable (pid_t, Int32) -> Int32? = { target, signal in
            kill(target, signal) == 0 ? nil : errno
        },
        nextEpochProvider: @escaping ProcessExitEpochProvider = { _, _, _, _ in nil }
    ) async -> Bool {
        let ttyDevice = commonTTYDevice(in: terminations)
        if processScopeKey != nil, ttyDevice == nil {
            return false
        }
        return await withTaskGroup(
            of: (didExit: Bool?, graceElapsed: Bool?).self
        ) { group in
            group.addTask(priority: .utility) {
                if let waitForExit {
                    return (await waitForExit(terminations), nil)
                }
                return (
                    await waitForScopedProcessGenerationsToExitWithoutTimeout(
                        terminations,
                        processScopeKey: processScopeKey,
                        nextEpochProvider: nextEpochProvider
                    ),
                    nil
                )
            }
            group.addTask(priority: .utility) {
                (nil, await sleepUntilDeadline(gracePeriod))
            }
            guard let firstEvent = await group.next() else { return false }
            if let didExit = firstEvent.didExit {
                group.cancelAll()
                return didExit
            }
            guard firstEvent.graceElapsed == true else {
                group.cancelAll()
                return false
            }

            let processGroupLeaders = processGroupLeaders(in: terminations)
            guard processGroupLeaders.count ==
                    Set(terminations.map(\.processGroupID)).filter({ $0 > 1 }).count,
                  let refreshedEpoch = await nextEpochProvider(
                      processGroupLeaders,
                      processScopeKey,
                      ttyDevice,
                      []
                  ) else {
                group.cancelAll()
                return false
            }

            let refreshedTerminations = refreshedEpoch.terminations
            if refreshedTerminations.isEmpty {
                let originalGenerationsExited = terminations.allSatisfy { termination in
                    processIdentityProvider(pid_t(termination.processID)) !=
                        termination.processIdentity
                }
                group.cancelAll()
                return originalGenerationsExited
            }
            guard refreshedTerminations.allSatisfy({ termination in
                let processID = pid_t(termination.processID)
                return processIdentityProvider(processID) ==
                        termination.processIdentity &&
                    processGroupProvider(processID) == termination.processGroupID
            }) else {
                group.cancelAll()
                return false
            }
            if let processScopeKey {
                guard refreshedTerminations.allSatisfy({ termination in
                          guard let ttyDevice = termination.ttyDevice else {
                              return false
                          }
                          return processTTYDeviceProvider(
                              pid_t(termination.processID)
                          ) == ttyDevice
                      }),
                      refreshedTerminations.allSatisfy({ termination in
                          processArgumentsProvider(termination.processID)?
                              .matchesCMUXScope(
                                  workspaceId: processScopeKey.workspaceId,
                                  surfaceId: processScopeKey.panelId
                              ) == true
                      }),
                      // Close same-generation exec and process-group races
                      // introduced by the uncached scope/TTY probes.
                      refreshedTerminations.allSatisfy({ termination in
                          let processID = pid_t(termination.processID)
                          return processIdentityProvider(processID) ==
                                  termination.processIdentity &&
                              processGroupProvider(processID) ==
                                  termination.processGroupID
                      }) else {
                    group.cancelAll()
                    return false
                }
            }
            for (processGroupID, leaderIdentity) in refreshedEpoch.processGroupLeaders {
                let liveLeader = processIdentityProvider(processGroupID)
                guard liveLeader == nil || liveLeader == leaderIdentity else {
                    continue
                }
                if let error = signalErrorProvider(-processGroupID, SIGKILL),
                   error != ESRCH {
                    group.cancelAll()
                    return false
                }
            }
            group.addTask(priority: .utility) {
                (nil, await sleepUntilDeadline(postKillExitPeriod))
            }
            guard let postKillEvent = await group.next() else { return false }
            if let didExit = postKillEvent.didExit {
                group.cancelAll()
                return didExit
            }
            group.cancelAll()
            return false
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func waitForScopedProcessGenerationsToExitWithoutTimeout(
        _ terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey? = nil,
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        waitForExactEpoch: (@Sendable ([ScopedProcessTermination]) async -> Bool)? = nil,
        nextEpochProvider: @escaping ProcessExitEpochProvider = { _, _, _, _ in nil }
    ) async -> Bool {
        let ttyDevice = commonTTYDevice(in: terminations)
        if processScopeKey != nil, ttyDevice == nil {
            return false
        }
        var processGroupLeaders = processGroupLeaders(in: terminations)
        guard processGroupLeaders.count ==
                Set(terminations.map(\.processGroupID)).filter({ $0 > 1 }).count else {
            return false
        }
        var epoch = terminations
        var exitedIdentities: Set<AgentPIDProcessIdentity> = []
        var refreshCount = 0
        while true {
            let didExit: Bool
            if let waitForExactEpoch {
                didExit = await waitForExactEpoch(epoch)
            } else {
                didExit = await waitForExactProcessGenerationsToExitWithoutTimeout(
                    epoch,
                    processIdentityProvider: processIdentityProvider
                )
            }
            guard didExit, !Task.isCancelled else { return false }
            exitedIdentities.formUnion(epoch.map(\.processIdentity))
            guard refreshCount < maximumProcessExitEpochRefreshCount else {
                return false
            }
            refreshCount += 1
            guard let nextEpoch = await nextEpochProvider(
                processGroupLeaders,
                processScopeKey,
                ttyDevice,
                exitedIdentities
            ) else {
                return false
            }
            guard !nextEpoch.terminations.isEmpty else { return true }
            processGroupLeaders = nextEpoch.processGroupLeaders
            epoch = nextEpoch.terminations
        }
    }

    nonisolated static func processGroupLeaders(
        in terminations: [ScopedProcessTermination]
    ) -> [pid_t: AgentPIDProcessIdentity] {
        Dictionary(
            uniqueKeysWithValues: terminations.compactMap { termination in
                let processGroupID = termination.processGroupID
                guard processGroupID > 1,
                      termination.processID == Int(processGroupID) else {
                    return nil
                }
                return (processGroupID, termination.processIdentity)
            }
        )
    }

    nonisolated static func commonTTYDevice(
        in terminations: [ScopedProcessTermination]
    ) -> Int64? {
        let ttyDevices = Set(terminations.compactMap(\.ttyDevice))
        guard ttyDevices.count == 1 else { return nil }
        return ttyDevices.first
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func waitForExactProcessGenerationsToExitWithoutTimeout(
        _ terminations: [ScopedProcessTermination],
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        }
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for termination in terminations {
                group.addTask(priority: .utility) {
                    await waitForExactProcessGenerationToExit(
                        termination,
                        processIdentityProvider: processIdentityProvider
                    )
                }
            }
            for await didExit in group where !didExit {
                group.cancelAll()
                return false
            }
            return true
        }
    }

    private nonisolated static func waitForExactProcessGenerationToExit(
        _ termination: ScopedProcessTermination,
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity?
    ) async -> Bool {
        let processID = pid_t(termination.processID)
        guard processIdentityProvider(processID) == termination.processIdentity else {
            return true
        }

        let exitEvents = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeProcessSource(
                identifier: processID,
                eventMask: .exit,
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }
        // Close the registration race without ever accepting a reused PID.
        guard processIdentityProvider(processID) == termination.processIdentity else {
            return true
        }

        for await _ in exitEvents {
            return true
        }
        return processIdentityProvider(processID) != termination.processIdentity
    }
}
