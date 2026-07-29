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
    /// Bounds synchronous exact-kernel validation in the final signal commit boundary.
    nonisolated static let maximumScopedProcessTerminationCount = 32
    /// Bounds full process-table refreshes while discovering late process generations.
    nonisolated static let maximumProcessExitEpochRefreshCount = 8

    struct ProcessTerminationScope: Sendable {
        let key: AgentHibernationPanelKey
        let processIDs: Set<Int>
        let processIdentities: [Int: AgentPIDProcessIdentity]
    }

    struct ScopedProcessTermination: Equatable, Sendable {
        let processID: Int
        let processIdentity: AgentPIDProcessIdentity
        let processGroupID: pid_t
        let ttyDevice: Int64?

        init(
            processID: Int,
            processIdentity: AgentPIDProcessIdentity,
            processGroupID: pid_t,
            ttyDevice: Int64? = nil
        ) {
            self.processID = processID
            self.processIdentity = processIdentity
            self.processGroupID = processGroupID
            self.ttyDevice = ttyDevice
        }
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
                            processGroupProvider: { getpgid(pid_t($0)) },
                            processTTYDeviceProvider: {
                                agentLiveProcessIdentity(pid: pid_t($0))?.ttyDevice
                            }
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
        processGroupProvider: (Int) -> pid_t,
        processTTYDeviceProvider: (Int) -> Int64? = {
            agentLiveProcessIdentity(pid: pid_t($0))?.ttyDevice
        }
    ) -> [ScopedProcessTermination]? {
        guard scope.processIDs.count <= maximumScopedProcessTerminationCount,
              Set(scope.processIdentities.keys) == scope.processIDs else {
            return nil
        }
        var terminations: [ScopedProcessTermination] = []
        for processID in scope.processIDs.sorted(by: >) {
            guard processID > 0,
                  processID <= Int(Int32.max),
                  let expectedIdentity = scope.processIdentities[processID],
                  processIdentityProvider(processID) == expectedIdentity else {
                return nil
            }
            terminations.append(
                ScopedProcessTermination(
                    processID: processID,
                    processIdentity: expectedIdentity,
                    processGroupID: processGroupProvider(processID),
                    ttyDevice: processTTYDeviceProvider(processID)
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
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        let committedTerminationRequestID = UUID()

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
                processIDs: record.processIDs,
                awaitProcessExit: {
                    await processExitCompletion.wait()
                }
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
        snapshot.map({
            AgentHibernationTranscriptGuard.liveFileVersionStillMatches($0)
        }) ?? true else {
            if let snapshot {
                await releaseArmedRestoreMonitorAfterAbortedTeardown(
                    snapshot,
                    sessionId: record.agent.sessionId,
                    restoreOwnedSnapshotPaths: &restoreOwnedSnapshotPaths
                )
            }
            return false
        }

        let lastActivityAt = Date(
            timeIntervalSince1970: request.effectiveLastActivityAt
        )
        let panelID = record.key.panelId
        let workspaceID = record.key.workspaceId
        let agent = record.agent
        let finalizeTeardown: @MainActor () -> Bool = {
            [weak workspace = record.workspace, weak terminalPanel = record.terminalPanel] in
            guard let terminalPanel else { return true }
            if let workspace,
               let currentPanel = workspace.panels[panelID] as? TerminalPanel,
               currentPanel === terminalPanel,
               terminalPanel.workspaceId == workspaceID,
               terminalPanel.isAgentHibernationCommitPending {
                return workspace.enterAgentHibernation(
                    panelId: panelID,
                    agent: agent,
                    lastActivityAt: lastActivityAt
                )
            }
            // A live move carries the phase on TerminalPanel. Its new owner
            // gets the same resumable state without consulting the source.
            terminalPanel.completeAgentHibernationTermination()
            return true
        }
        let finishTeardown: @MainActor () async -> Bool = {
            [weak terminalPanel = record.terminalPanel] in
            guard let terminalPanel else { return true }
            guard await terminalPanel.surface.waitForAgentHibernationRuntimeTeardown(
                timeout: .seconds(5)
            ) else {
                return false
            }
            return finalizeTeardown()
        }
        let recoverTeardown: @MainActor () async -> Void = {
            [weak terminalPanel = record.terminalPanel] in
            guard terminalPanel != nil else { return }
            _ = finalizeTeardown()
        }
        let waitForRecoveryReadiness: @MainActor @Sendable () async -> Bool = {
            [weak terminalPanel = record.terminalPanel] in
            guard let terminalPanel else { return true }
            return await terminalPanel.surface.waitForAgentHibernationRuntimeTeardown(
                timeout: .seconds(30)
            )
        }
        let beginTerminationRecovery: @MainActor () async -> Void = {
            [weak terminalPanel = record.terminalPanel] in
            terminalPanel?.beginAgentHibernationTerminationRecovery()
        }
        let handleRecoveryFailure: @MainActor () async -> Void = {
            [weak self, weak terminalPanel = record.terminalPanel] in
            guard let self, let terminalPanel else { return }
            terminalPanel.failAgentHibernationTermination()
            terminalPanel.onRequestAgentHibernationTerminationRetry = {
                [weak self, weak terminalPanel] in
                guard let self, let terminalPanel else { return }
                self.retryCommittedTerminationRecovery(panelID: terminalPanel.id)
            }
        }
        let beginRecoveryRetry: @MainActor () -> Void = {
            [weak terminalPanel = record.terminalPanel] in
            terminalPanel?.beginAgentHibernationTerminationRecovery()
        }
        let finalCommitIsSafe: @MainActor @Sendable () -> Bool = {
            [weak self, weak terminalPanel = record.terminalPanel] in
            guard let self, let terminalPanel,
                  self.teardownIsStillSafe(
                request,
                index: preSignalIndex,
                shouldProceed: shouldProceed
                  ),
                  (snapshot.map {
                    AgentHibernationTranscriptGuard.liveFileVersionStillMatches($0)
                  } ?? true) else {
                return false
            }
            return terminalPanel.surface.reserveAgentHibernationRuntimeTeardown()
        }
        let processGroupLeaders = Self.processGroupLeaders(
            in: scopedProcessTerminations
        )
        let processScopeKey = record.key
        let processSnapshotCoordinator = processSnapshotCoordinator
        let retryTerminationIsSafe: @MainActor @Sendable () -> Bool = {
            [weak self, weak terminalPanel = record.terminalPanel] in
            guard let self, let terminalPanel,
                  terminalPanel.isAgentHibernationCommitPending,
                  self.committedTerminationObservationsByPanelID[panelID]?
                    .requestID == committedTerminationRequestID else {
                return false
            }
            return true
        }
        let retryTermination: CommittedTerminationRetry = {
            guard !scopedProcessTerminations.isEmpty else {
                return .exited
            }
            guard let epoch = await processSnapshotCoordinator.refreshedExitEpoch(
                processGroupLeaders: processGroupLeaders,
                processScopeKey: processScopeKey,
                ttyDevice: Self.commonTTYDevice(in: scopedProcessTerminations),
                excluding: []
            ) else {
                return .rejected
            }
            return await Self.terminateScopedProcessEpochForHibernation(
                epoch,
                processScopeKey: processScopeKey,
                shouldCommit: retryTerminationIsSafe
            )
        }
        let terminationResult = await Self.terminateScopedProcessesForHibernation(
            scopedProcessTerminations,
            processScopeKey: record.key,
            shouldCommit: finalCommitIsSafe,
            onTeardownCommit: {
                [self, weak terminalPanel = record.terminalPanel] in
                registerCommittedTerminationObservation(
                    panelID: panelID,
                    requestID: committedTerminationRequestID,
                    processExitCompletion: processExitCompletion
                )
                terminalPanel?.beginAgentHibernationTermination(
                    agent: agent,
                    lastActivityAt: lastActivityAt
                )
            }
        )
        switch terminationResult {
        case .rejected:
            record.terminalPanel.surface
                .cancelAgentHibernationRuntimeTeardownReservation()
            if let snapshot {
                await releaseArmedRestoreMonitorAfterAbortedTeardown(
                    snapshot,
                    sessionId: record.agent.sessionId,
                    restoreOwnedSnapshotPaths: &restoreOwnedSnapshotPaths
                )
            }
            return false
        case .exited:
            guard committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    committedTerminationRequestID else {
                return false
            }
            await processExitCompletion.finish(true)
            guard committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    committedTerminationRequestID else {
                return false
            }
            guard await finishTeardown() else {
                guard committedTerminationObservationsByPanelID[panelID]?.requestID ==
                        committedTerminationRequestID else {
                    return false
                }
                await beginTerminationRecovery()
                guard committedTerminationObservationsByPanelID[panelID]?.requestID ==
                        committedTerminationRequestID else {
                    return false
                }
                observeCommittedTerminationRecovery(
                    panelID: panelID,
                    requestID: committedTerminationRequestID,
                    terminations: [],
                    processScopeKey: nil,
                    processExitCompletion: processExitCompletion,
                    retryTermination: retryTermination,
                    waitForRecoveryReadiness: waitForRecoveryReadiness,
                    recoveryDeadline: .seconds(60),
                    onRecovery: recoverTeardown,
                    onRecoveryFailure: handleRecoveryFailure,
                    onRecoveryRetry: beginRecoveryRetry
                )
                return false
            }
            guard committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    committedTerminationRequestID else {
                return false
            }
            removeCommittedTerminationObservation(
                panelID: panelID,
                requestID: committedTerminationRequestID
            )
        case .committedAwaitingExit:
            observeCommittedTermination(
                panelID: panelID,
                requestID: committedTerminationRequestID,
                terminations: scopedProcessTerminations,
                processScopeKey: record.key,
                processExitCompletion: processExitCompletion,
                retryTermination: retryTermination,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: .seconds(60),
                onExit: finishTeardown,
                onFailure: beginTerminationRecovery,
                onRecovery: recoverTeardown,
                onRecoveryFailure: handleRecoveryFailure,
                onRecoveryRetry: beginRecoveryRetry
            )
            return false
        }

        return record.terminalPanel.isAgentHibernated &&
            !record.terminalPanel.isAgentHibernationTerminating
    }

}
