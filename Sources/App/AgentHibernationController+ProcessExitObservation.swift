import Foundation

extension AgentHibernationController {
    typealias CommittedTerminationRetry =
        @Sendable () async -> ScopedProcessTerminationResult

    func observeCommittedTermination(
        panelID: UUID,
        requestID: UUID? = nil,
        terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey? = nil,
        processExitCompletion: AgentHibernationProcessExitCompletion =
            AgentHibernationProcessExitCompletion(),
        waitForExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)? = nil,
        waitForRecoveryExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)? = nil,
        retryTermination: CommittedTerminationRetry? = nil,
        waitForRecoveryReadiness: @escaping @MainActor @Sendable () async -> Bool = { true },
        recoveryDeadline: Duration = .seconds(30),
        sleepUntilRecoveryDeadline: @escaping @Sendable (Duration) async -> Bool = {
            duration in
            do {
                // Genuine recovery deadline; cancellation aborts the wait.
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        },
        onExit: @escaping @MainActor () async -> Bool,
        onFailure: @escaping @MainActor () async -> Void = {},
        onRecovery: @escaping @MainActor () async -> Void,
        onRecoveryFailure: @escaping @MainActor () async -> Void = {},
        onRecoveryRetry: @escaping @MainActor () -> Void = {}
    ) {
        let observationRequestID: UUID
        if let requestID {
            guard let observation = committedTerminationObservationsByPanelID[panelID],
                  observation.requestID == requestID,
                  observation.processExitCompletion === processExitCompletion else {
                return
            }
            observationRequestID = requestID
        } else {
            observationRequestID = registerCommittedTerminationObservation(
                panelID: panelID,
                processExitCompletion: processExitCompletion
            )
        }
        let nextEpochProvider = processExitEpochProvider()
        let task = Task { @MainActor [weak self] in
            let didExit = await Self.waitForScopedProcessGenerationsToExitAfterEscalation(
                terminations,
                processScopeKey: processScopeKey,
                waitForExit: waitForExit,
                nextEpochProvider: nextEpochProvider
            )
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    observationRequestID,
                  !Task.isCancelled else {
                return
            }
            if didExit {
                await processExitCompletion.finish(true)
            }
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    observationRequestID,
                  !Task.isCancelled else {
                return
            }
            let didFinish = didExit ? await onExit() : false
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    observationRequestID,
                  !Task.isCancelled else {
                return
            }
            if didFinish {
                self.removeCommittedTerminationObservation(
                    panelID: panelID,
                    requestID: observationRequestID
                )
                return
            }
            await onFailure()
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    observationRequestID,
                  !Task.isCancelled else {
                return
            }
            self.replaceCommittedTerminationWithRecoveryObservation(
                panelID: panelID,
                requestID: observationRequestID,
                terminations: terminations,
                processScopeKey: processScopeKey,
                processExitCompletion: processExitCompletion,
                waitForRecoveryExit: waitForRecoveryExit,
                retryTermination: retryTermination,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: recoveryDeadline,
                sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                nextEpochProvider: nextEpochProvider,
                onRecovery: onRecovery,
                onRecoveryFailure: onRecoveryFailure,
                onRecoveryRetry: onRecoveryRetry
            )
        }
        replaceCommittedTerminationTask(
            panelID: panelID,
            requestID: observationRequestID,
            with: task
        )
    }

    func observeCommittedTerminationRecovery(
        panelID: UUID,
        requestID: UUID? = nil,
        terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey? = nil,
        processExitCompletion: AgentHibernationProcessExitCompletion =
            AgentHibernationProcessExitCompletion(),
        waitForRecoveryExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)? = nil,
        retryTermination: CommittedTerminationRetry? = nil,
        waitForRecoveryReadiness: @escaping @MainActor @Sendable () async -> Bool = { true },
        recoveryDeadline: Duration = .seconds(30),
        sleepUntilRecoveryDeadline: @escaping @Sendable (Duration) async -> Bool = {
            duration in
            do {
                // Genuine recovery deadline; cancellation aborts the wait.
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        },
        onRecovery: @escaping @MainActor () async -> Void,
        onRecoveryFailure: @escaping @MainActor () async -> Void = {},
        onRecoveryRetry: @escaping @MainActor () -> Void = {}
    ) {
        let observationRequestID: UUID
        if let requestID {
            guard let observation = committedTerminationObservationsByPanelID[panelID],
                  observation.requestID == requestID,
                  observation.processExitCompletion === processExitCompletion else {
                return
            }
            observationRequestID = requestID
        } else {
            observationRequestID = registerCommittedTerminationObservation(
                panelID: panelID,
                processExitCompletion: processExitCompletion
            )
        }
        replaceCommittedTerminationWithRecoveryObservation(
            panelID: panelID,
            requestID: observationRequestID,
            terminations: terminations,
            processScopeKey: processScopeKey,
            processExitCompletion: processExitCompletion,
            waitForRecoveryExit: waitForRecoveryExit,
            retryTermination: retryTermination,
            waitForRecoveryReadiness: waitForRecoveryReadiness,
            recoveryDeadline: recoveryDeadline,
            sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
            nextEpochProvider: processExitEpochProvider(),
            onRecovery: onRecovery,
            onRecoveryFailure: onRecoveryFailure,
            onRecoveryRetry: onRecoveryRetry
        )
    }

    func retryCommittedTerminationRecovery(panelID: UUID) {
        committedTerminationObservationsByPanelID[panelID]?.retryRecovery?()
    }

    private func replaceCommittedTerminationWithRecoveryObservation(
        panelID: UUID,
        requestID: UUID,
        terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey?,
        processExitCompletion: AgentHibernationProcessExitCompletion,
        waitForRecoveryExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)?,
        retryTermination: CommittedTerminationRetry?,
        waitForRecoveryReadiness: @escaping @MainActor @Sendable () async -> Bool,
        recoveryDeadline: Duration,
        sleepUntilRecoveryDeadline: @escaping @Sendable (Duration) async -> Bool,
        nextEpochProvider: @escaping ProcessExitEpochProvider,
        onRecovery: @escaping @MainActor () async -> Void,
        onRecoveryFailure: @escaping @MainActor () async -> Void,
        onRecoveryRetry: @escaping @MainActor () -> Void
    ) {
        guard let observation = committedTerminationObservationsByPanelID[panelID],
              observation.requestID == requestID else {
            return
        }
        let recoveryTask = Task { @MainActor [weak self] in
            let didRecover = await Self.waitForCommittedTerminationRecovery(
                terminations: terminations,
                processScopeKey: processScopeKey,
                waitForRecoveryExit: waitForRecoveryExit,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: recoveryDeadline,
                sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                nextEpochProvider: nextEpochProvider
            )
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }
            guard didRecover else {
                await onRecoveryFailure()
                return
            }
            await processExitCompletion.finish(true)
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }
            await onRecovery()
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }
            self.removeCommittedTerminationObservation(
                panelID: panelID,
                requestID: requestID
            )
        }
        observation.retryRecovery = { @MainActor [weak self] in
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID else {
                return
            }
            onRecoveryRetry()
            if let retryTermination {
                self.replaceCommittedTerminationWithRetryObservation(
                    panelID: panelID,
                    requestID: requestID,
                    terminations: terminations,
                    processScopeKey: processScopeKey,
                    processExitCompletion: processExitCompletion,
                    waitForRecoveryExit: waitForRecoveryExit,
                    retryTermination: retryTermination,
                    waitForRecoveryReadiness: waitForRecoveryReadiness,
                    recoveryDeadline: recoveryDeadline,
                    sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                    nextEpochProvider: nextEpochProvider,
                    onRecovery: onRecovery,
                    onRecoveryFailure: onRecoveryFailure,
                    onRecoveryRetry: onRecoveryRetry
                )
                return
            }
            self.replaceCommittedTerminationWithRecoveryObservation(
                panelID: panelID,
                requestID: requestID,
                terminations: terminations,
                processScopeKey: processScopeKey,
                processExitCompletion: processExitCompletion,
                waitForRecoveryExit: waitForRecoveryExit,
                retryTermination: nil,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: recoveryDeadline,
                sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                nextEpochProvider: nextEpochProvider,
                onRecovery: onRecovery,
                onRecoveryFailure: onRecoveryFailure,
                onRecoveryRetry: onRecoveryRetry
            )
        }
        replaceCommittedTerminationTask(
            panelID: panelID,
            requestID: requestID,
            with: recoveryTask
        )
    }

    private func replaceCommittedTerminationWithRetryObservation(
        panelID: UUID,
        requestID: UUID,
        terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey?,
        processExitCompletion: AgentHibernationProcessExitCompletion,
        waitForRecoveryExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)?,
        retryTermination: @escaping CommittedTerminationRetry,
        waitForRecoveryReadiness: @escaping @MainActor @Sendable () async -> Bool,
        recoveryDeadline: Duration,
        sleepUntilRecoveryDeadline: @escaping @Sendable (Duration) async -> Bool,
        nextEpochProvider: @escaping ProcessExitEpochProvider,
        onRecovery: @escaping @MainActor () async -> Void,
        onRecoveryFailure: @escaping @MainActor () async -> Void,
        onRecoveryRetry: @escaping @MainActor () -> Void
    ) {
        guard let observation = committedTerminationObservationsByPanelID[panelID],
              observation.requestID == requestID else {
            return
        }
        let retryTask = Task { @MainActor [weak self] in
            let terminationResult = await retryTermination()
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }

            let didExit: Bool
            switch terminationResult {
            case .rejected:
                await onRecoveryFailure()
                return
            case .exited:
                didExit = true
            case .committedAwaitingExit:
                didExit = await Self.waitForScopedProcessGenerationsToExitAfterEscalation(
                    terminations,
                    processScopeKey: processScopeKey,
                    waitForExit: waitForRecoveryExit,
                    nextEpochProvider: nextEpochProvider
                )
            }
            if didExit {
                await processExitCompletion.finish(true)
            }
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }

            let didRecover = await Self.waitForCommittedTerminationRecovery(
                terminations: didExit ? [] : terminations,
                processScopeKey: processScopeKey,
                waitForRecoveryExit: didExit
                    ? Self.completedRecoveryExitWait
                    : waitForRecoveryExit,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: recoveryDeadline,
                sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                nextEpochProvider: nextEpochProvider
            )
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }
            guard didRecover else {
                await onRecoveryFailure()
                return
            }
            await processExitCompletion.finish(true)
            await onRecovery()
            guard self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID,
                  !Task.isCancelled else {
                return
            }
            self.removeCommittedTerminationObservation(
                panelID: panelID,
                requestID: requestID
            )
        }
        observation.retryRecovery = { @MainActor [weak self] in
            guard let self,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    requestID else {
                return
            }
            onRecoveryRetry()
            self.replaceCommittedTerminationWithRetryObservation(
                panelID: panelID,
                requestID: requestID,
                terminations: terminations,
                processScopeKey: processScopeKey,
                processExitCompletion: processExitCompletion,
                waitForRecoveryExit: waitForRecoveryExit,
                retryTermination: retryTermination,
                waitForRecoveryReadiness: waitForRecoveryReadiness,
                recoveryDeadline: recoveryDeadline,
                sleepUntilRecoveryDeadline: sleepUntilRecoveryDeadline,
                nextEpochProvider: nextEpochProvider,
                onRecovery: onRecovery,
                onRecoveryFailure: onRecoveryFailure,
                onRecoveryRetry: onRecoveryRetry
            )
        }
        replaceCommittedTerminationTask(
            panelID: panelID,
            requestID: requestID,
            with: retryTask
        )
    }

    private nonisolated static func waitForCommittedTerminationRecovery(
        terminations: [ScopedProcessTermination],
        processScopeKey: AgentHibernationPanelKey?,
        waitForRecoveryExit: (@Sendable ([ScopedProcessTermination]) async -> Bool)?,
        waitForRecoveryReadiness: @escaping @MainActor @Sendable () async -> Bool,
        recoveryDeadline: Duration,
        sleepUntilRecoveryDeadline: @escaping @Sendable (Duration) async -> Bool,
        nextEpochProvider: @escaping ProcessExitEpochProvider
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask(priority: .utility) {
                guard await waitForRecoveryReadiness() else { return false }
                if let waitForRecoveryExit {
                    return await waitForRecoveryExit(terminations)
                }
                return await waitForScopedProcessGenerationsToExitWithoutTimeout(
                    terminations,
                    processScopeKey: processScopeKey,
                    nextEpochProvider: nextEpochProvider
                )
            }
            group.addTask(priority: .utility) {
                guard await sleepUntilRecoveryDeadline(recoveryDeadline) else {
                    return false
                }
                return false
            }
            let recovered = await group.next() ?? false
            group.cancelAll()
            return recovered
        }
    }

    private func processExitEpochProvider() -> ProcessExitEpochProvider {
        {
            [processSnapshotCoordinator]
            processGroupLeaders,
            processScopeKey,
            ttyDevice,
            exitedIdentities in
            await processSnapshotCoordinator.refreshedExitEpoch(
                processGroupLeaders: processGroupLeaders,
                processScopeKey: processScopeKey,
                ttyDevice: ttyDevice,
                excluding: exitedIdentities
            )
        }
    }

    private nonisolated static let completedRecoveryExitWait:
        @Sendable ([ScopedProcessTermination]) async -> Bool = { _ in true }

}
