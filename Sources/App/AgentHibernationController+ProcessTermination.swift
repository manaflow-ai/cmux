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
    private nonisolated static let processExitTimeout: Duration = .seconds(30)

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

    func commitConfirmedTeardown(
        _ request: ConfirmedTeardownRequest,
        snapshotOutcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome,
        scopedProcessTerminations: [ScopedProcessTermination],
        shouldProceed: (@MainActor () -> Bool)?,
        restoreOwnedSnapshotPaths: inout Set<String>
    ) async -> Bool {
        let record = request.record
        let snapshot: AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot?
        switch snapshotOutcome {
        case .snapshot(let value):
            snapshot = value
        case .nothingToProtect:
            snapshot = nil
        case .unableToProtect:
            // Forfeit hibernation rather than risk issue #6565 transcript loss.
            unableToProtectByPanel[record.key] = UnableToProtectMarker(
                fingerprint: request.confirmationFingerprint,
                lastActivityAt: request.effectiveLastActivityAt,
                retryAfter: Date.now.timeIntervalSince1970 + Self.unableToProtectRetrySeconds
            )
            return false
        }

        if let snapshot {
            // Hand off any older monitor only after every other precondition passed.
            await cancelPostTeardownRestoreTaskForReplacement(
                transcriptPath: snapshot.transcriptPath
            )
            guard shouldProceed?() ?? true else {
                preserveSnapshotAfterAbortedTeardown(
                    snapshot,
                    record: record,
                    restoreOwnedSnapshotPaths: &restoreOwnedSnapshotPaths
                )
                return false
            }
            guard AgentHibernationTranscriptGuard.liveFileVersionStillMatches(snapshot) else {
                unableToProtectByPanel[record.key] = UnableToProtectMarker(
                    fingerprint: request.confirmationFingerprint,
                    lastActivityAt: request.effectiveLastActivityAt,
                    retryAfter: Date.now.timeIntervalSince1970 + Self.unableToProtectRetrySeconds
                )
                preserveSnapshotAfterAbortedTeardown(
                    snapshot,
                    record: record,
                    restoreOwnedSnapshotPaths: &restoreOwnedSnapshotPaths
                )
                return false
            }
            // Protection must already be active when SIGTERM or PTY closure can
            // trigger an interrupted-exit transcript rewrite.
            guard armPostTeardownRestoreMonitor(
                snapshot: snapshot,
                processIDs: record.processIDs
            ) else {
                preserveSnapshotAfterAbortedTeardown(
                    snapshot,
                    record: record,
                    restoreOwnedSnapshotPaths: &restoreOwnedSnapshotPaths
                )
                return false
            }
            restoreOwnedSnapshotPaths.insert(snapshot.snapshotPath)
        }

        let terminalInputAtCommit = terminalInputByPanel[record.key] ?? 0
        guard shouldProceed?() ?? true,
              await terminateScopedProcessesForHibernation(scopedProcessTerminations) else {
            return false
        }
        let postTerminationIndex: RestorableAgentSessionIndex?
        if scopedProcessTerminations.isEmpty {
            postTerminationIndex = nil
        } else {
            postTerminationIndex = await RestorableAgentSessionIndex
                .loadIncludingProcessDetectedSnapshots()
        }
        let postTerminationStateIsValid: Bool
        if let postTerminationIndex {
            postTerminationStateIsValid =
                postTerminationIndex.processIDs(
                    workspaceId: record.key.workspaceId,
                    panelId: record.key.panelId
                ).isEmpty &&
                (terminalInputByPanel[record.key] ?? 0) == terminalInputAtCommit
        } else {
            postTerminationStateIsValid =
                record.workspace.agentHibernationLifecycleState(
                    panelId: record.key.panelId,
                    fallback: record.lifecycle
                ).allowsHibernation &&
                (terminalInputByPanel[record.key] ?? 0) <=
                    (lifecycleChangeByPanel[record.key] ?? 0) &&
                (teardownValidationEpochByPanel[record.key] ?? 0) == request.epoch &&
                hibernationFingerprint(for: record) == request.confirmationFingerprint &&
                (activityByPanel[record.key] ?? 0) <= request.effectiveLastActivityAt
        }
        guard postTerminationStateIsValid,
              shouldProceed?() ?? true,
              AgentHibernationTrackingGate.isEnabled(),
              record.isStillOwnedByOriginalWorkspace,
              !record.terminalPanel.isAgentHibernated,
              record.terminalPanel.surface.hasLiveSurface,
              AppDelegate.shared?.agentHibernationPanelIsProtected(
                  workspace: record.workspace,
                  panelId: record.key.panelId
              ) == false,
              teardownValidationGeneration == request.generation else {
            return false
        }

        record.workspace.enterAgentHibernation(
            panelId: record.key.panelId,
            agent: record.agent,
            lastActivityAt: Date(timeIntervalSince1970: request.effectiveLastActivityAt)
        )
        return true
    }

    @discardableResult
    func terminateScopedProcessesForHibernation(
        _ terminations: [ScopedProcessTermination],
        currentProcessID: pid_t = getpid(),
        currentProcessGroupID: pid_t = getpgrp(),
        processIdentityProvider: (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: (pid_t) -> pid_t = { getpgid($0) },
        signalErrorProvider: (pid_t, Int32) -> Int32? = { target, signal in
            kill(target, signal) == 0 ? nil : errno
        },
        waitForExit: @escaping @Sendable ([ScopedProcessTermination]) async -> Bool = {
            await AgentHibernationController.waitForExactProcessGenerationsToExit($0)
        }
    ) async -> Bool {
        guard !terminations.isEmpty else { return true }
        guard terminations.allSatisfy({ termination in
            let pid = pid_t(termination.processID)
            return pid != currentProcessID &&
                processIdentityProvider(pid) == termination.processIdentity &&
                processGroupProvider(pid) == termination.processGroupID
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
                if let error = signalErrorProvider(-processGroupID, SIGTERM),
                   error != ESRCH {
                    return false
                }
            }
            if let error = signalErrorProvider(pid, SIGTERM),
               error != ESRCH {
                return false
            }
        }
        return await waitForExit(terminations)
    }

    nonisolated static func waitForExactProcessGenerationsToExit(
        _ terminations: [ScopedProcessTermination],
        timeout: Duration = processExitTimeout,
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        }
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for termination in terminations {
                group.addTask(priority: .utility) {
                    await waitForExactProcessGenerationToExit(
                        termination,
                        timeout: timeout,
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
        timeout: Duration,
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

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exitEvents {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return false
                }
                return processIdentityProvider(processID) != termination.processIdentity
            }
            let didExit = await group.next() ?? false
            group.cancelAll()
            return didExit
        }
    }
}
