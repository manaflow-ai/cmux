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

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
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

        // The monitor handoff above awaits an older task and makes the main actor
        // reentrant. Refresh the process generation snapshot, then re-check every
        // mutable safety condition at the last synchronous boundary before SIGTERM.
        let preSignalIndex = await RestorableAgentSessionIndex
            .loadIncludingProcessDetectedSnapshots()
        guard teardownIsStillSafe(
            request,
            index: preSignalIndex,
            shouldProceed: shouldProceed
        ),
        snapshot.map(AgentHibernationTranscriptGuard.liveFileVersionStillMatches) ?? true else {
            return false
        }

        let lastActivityAt = Date(
            timeIntervalSince1970: request.effectiveLastActivityAt
        )
        let panelID = record.key.panelId
        let workspaceID = record.key.workspaceId
        let agent = record.agent
        let finishTeardown: @MainActor () -> Void = {
            [weak workspace = record.workspace, weak terminalPanel = record.terminalPanel] in
            guard let terminalPanel else { return }
            if let workspace,
               let currentPanel = workspace.panels[panelID] as? TerminalPanel,
               currentPanel === terminalPanel,
               terminalPanel.workspaceId == workspaceID,
               terminalPanel.isAgentHibernationTerminating {
                workspace.enterAgentHibernation(
                    panelId: panelID,
                    agent: agent,
                    lastActivityAt: lastActivityAt
                )
            } else {
                // A live move carries the phase on TerminalPanel. Its new owner
                // gets the same resumable state without consulting the source.
                terminalPanel.completeAgentHibernationTermination()
            }
        }
        let terminationResult = terminateScopedProcessesForHibernation(
            scopedProcessTerminations,
            onTeardownCommit: {
                record.terminalPanel.beginAgentHibernationTermination(
                    agent: record.agent,
                    lastActivityAt: lastActivityAt
                )
            }
        )
        switch terminationResult {
        case .rejected:
            return false
        case .exited:
            finishTeardown()
        case .committedAwaitingExit:
            observeCommittedTermination(
                panelID: panelID,
                terminations: scopedProcessTerminations,
                onExit: finishTeardown
            )
            return false
        }

        return record.terminalPanel.isAgentHibernated &&
            !record.terminalPanel.isAgentHibernationTerminating
    }

    @discardableResult
    func terminateScopedProcessesForHibernation(
        _ terminations: [ScopedProcessTermination],
        onTeardownCommit: @MainActor () -> Void = {},
        currentProcessID: pid_t = getpid(),
        currentProcessGroupID: pid_t = getpgrp(),
        processIdentityProvider: (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: (pid_t) -> pid_t = { getpgid($0) },
        signalErrorProvider: (pid_t, Int32) -> Int32? = { target, signal in
            kill(target, signal) == 0 ? nil : errno
        }
    ) -> ScopedProcessTerminationResult {
        guard !terminations.isEmpty else {
            onTeardownCommit()
            return .exited
        }
        guard terminations.allSatisfy({ termination in
            let pid = pid_t(termination.processID)
            return pid != currentProcessID &&
                processIdentityProvider(pid) == termination.processIdentity &&
                processGroupProvider(pid) == termination.processGroupID
        }) else {
            return .rejected
        }
        var teardownIsCommitted = false
        let commitTeardownIfNeeded = {
            guard !teardownIsCommitted else { return }
            teardownIsCommitted = true
            onTeardownCommit()
        }
        var signaledProcessGroups: Set<pid_t> = []
        for termination in terminations {
            let pid = pid_t(termination.processID)
            let processGroupID = termination.processGroupID
            if processGroupID > 1,
               processGroupID != currentProcessGroupID,
               signaledProcessGroups.insert(processGroupID).inserted {
                if let error = signalErrorProvider(-processGroupID, SIGTERM) {
                    if error != ESRCH, !teardownIsCommitted {
                        return .rejected
                    }
                } else {
                    commitTeardownIfNeeded()
                }
            }
            if let error = signalErrorProvider(pid, SIGTERM) {
                if error != ESRCH, !teardownIsCommitted {
                    return .rejected
                }
            } else {
                commitTeardownIfNeeded()
            }
        }
        // Every target may have exited between validation and signaling. That is
        // still a committed teardown: there is no live generation left to kill.
        commitTeardownIfNeeded()
        // A later signal error cannot roll back a teardown after the first signal.
        // Exact-generation exit is completed by a stored per-panel observation so
        // one slow process cannot block later critical-pressure reclamation batches.
        return .committedAwaitingExit
    }

    func observeCommittedTermination(
        panelID: UUID,
        terminations: [ScopedProcessTermination],
        waitForExit: @escaping @Sendable ([ScopedProcessTermination]) async -> Bool = {
            await AgentHibernationController
                .waitForExactProcessGenerationsToExitWithoutTimeout($0)
        },
        onExit: @escaping @MainActor () -> Void
    ) {
        committedTerminationObservationsByPanelID
            .removeValue(forKey: panelID)?
            .task
            .cancel()
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            let didExit = await waitForExit(terminations)
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID else {
                return
            }
            self.committedTerminationObservationsByPanelID.removeValue(forKey: panelID)
            guard didExit, !Task.isCancelled else { return }
            onExit()
        }
        committedTerminationObservationsByPanelID[panelID] = CommittedTerminationObservation(
            requestID: requestID,
            task: task
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
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
