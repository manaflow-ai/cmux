import CmuxTerminalCore
import Foundation

/// Debounces prompt candidates and verifies their exact foreground process before notifying.
actor PromptTurnNotificationHandler {
    private let workspaceID: UUID
    private let surfaceID: UUID

    private var latestRevisionByAgentID: [String: UInt64] = [:]
    private var latestSubmissionCountByAgentID: [String: UInt64] = [:]
    private var turnForegroundPIDByAgentID: [String: Int] = [:]
    private var deliveredConfirmationIdentifiersByAgentID: [String: Set<UInt64>] = [:]
    private var deliveredConfirmationOrderByAgentID: [String: [UInt64]] = [:]
    private var deliveringConfirmationIdentifiersByAgentID: [String: Set<UInt64>] = [:]
    private var debounceTasksByAgentID: [String: Task<Void, Never>] = [:]
    private var saturationRetryTasksByConfirmation: [SaturationRetryKey: Task<Void, Never>] = [:]
    private var saturationRetryOrderByAgentID: [String: [UInt64]] = [:]

    private var inFlightPID: Int?
    private var inFlightVerification: Task<CmuxTaskManagerCodingAgentDefinition?, Never>?

    private static let maximumSaturationRetryAttempts = 5
    private static let maximumPendingSaturationRetriesPerAgent = 16
    private static let maximumRememberedDeliveredConfirmationsPerAgent = 128

    private struct SaturationRetryKey: Hashable {
        let agentID: String
        let confirmationIdentifier: UInt64
    }

    init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    deinit {
        for task in debounceTasksByAgentID.values {
            task.cancel()
        }
        for task in saturationRetryTasksByConfirmation.values {
            task.cancel()
        }
        inFlightVerification?.cancel()
    }

    /// Replaces the pending candidate for an agent with a newer detector revision.
    func update(
        agentID: String,
        submissionCount: UInt64,
        revision: UInt64,
        confirmation: PromptLineTurnConfirmation?,
        deadline: ContinuousClock.Instant?,
        locallyConfirmed: [PromptLineTurnConfirmation]
    ) async {
        if submissionCount > latestSubmissionCountByAgentID[agentID, default: 0] {
            latestSubmissionCountByAgentID[agentID] = submissionCount
            // Bind the turn to the process that received the submission so a
            // prompt from a later process in the same pane cannot complete a
            // turn it never ran. A nil foreground PID clears the binding and
            // fails closed at the delivery deadline.
            turnForegroundPIDByAgentID[agentID] = await Self.currentTurnContext(
                surfaceID: surfaceID,
                preferredWorkspaceID: workspaceID
            )?.foregroundPID
        }
        for confirmed in locallyConfirmed {
            // The detector already confirmed these turns synchronously at
            // their deadlines. Deliver them here so a delayed debounce task
            // cannot be cancelled out of a completion it was about to report.
            await deliverVerifiedTurn(
                agentID: agentID,
                confirmation: confirmed,
                requiredRevision: nil
            )
        }
        guard revision > latestRevisionByAgentID[agentID, default: 0] else { return }
        latestRevisionByAgentID[agentID] = revision
        debounceTasksByAgentID.removeValue(forKey: agentID)?.cancel()
        guard let confirmation, let deadline else { return }

        let clock = ContinuousClock()
        // This cancellable clock delay is the intended prompt-boundary debounce.
        debounceTasksByAgentID[agentID] = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.confirmationDeadlineReached(
                agentID: agentID,
                revision: revision,
                confirmation: confirmation
            )
        }
    }

    private func confirmationDeadlineReached(
        agentID: String,
        revision: UInt64,
        confirmation: PromptLineTurnConfirmation
    ) async {
        guard latestRevisionByAgentID[agentID] == revision else { return }
        debounceTasksByAgentID.removeValue(forKey: agentID)
        await deliverVerifiedTurn(
            agentID: agentID,
            confirmation: confirmation,
            requiredRevision: revision
        )
    }

    private func deliverVerifiedTurn(
        agentID: String,
        confirmation: PromptLineTurnConfirmation,
        requiredRevision: UInt64?,
        saturationRetryAttempt: Int = 0
    ) async {
        guard confirmation.confirmedTurnCount > 0,
              !hasDeliveredConfirmation(agentID: agentID, identifier: confirmation.identifier),
              let turnPID = turnForegroundPIDByAgentID[agentID],
              let context = await Self.currentTurnContext(
                  surfaceID: surfaceID,
                  preferredWorkspaceID: workspaceID
              ),
              context.foregroundPID == turnPID,
              let definition = await verifiedDefinition(
                  foregroundPID: context.foregroundPID,
                  agentID: agentID
              ),
              let recheck = await Self.currentTurnContext(
                  surfaceID: surfaceID,
                  preferredWorkspaceID: workspaceID
              ),
              recheck.foregroundPID == context.foregroundPID else {
            return
        }
        if let requiredRevision, latestRevisionByAgentID[agentID] != requiredRevision {
            return
        }
        // Re-check after the suspension points above so concurrent local and
        // timer confirmations of the same candidate deliver exactly once.
        guard beginDeliveringConfirmation(agentID: agentID, identifier: confirmation.identifier) else {
            return
        }

        let result = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: recheck.workspaceID,
            surfaceID: surfaceID,
            title: definition.displayName,
            subtitle: String(
                localized: "agent.generic.notification.subtitle.completed",
                defaultValue: "Completed"
            ),
            body: String(
                localized: "agent.generic.notification.body.taskCompleted",
                defaultValue: "Task completed"
            ),
            category: .turnComplete,
            pending: false,
            allowWorkspaceFallbackForValidatedSurface: true
        )
        endDeliveringConfirmation(agentID: agentID, identifier: confirmation.identifier)
        if result != .saturated {
            markDeliveredConfirmation(agentID: agentID, identifier: confirmation.identifier)
        } else {
            scheduleSaturationRetry(
                agentID: agentID,
                confirmation: confirmation,
                requiredRevision: nil,
                attempt: saturationRetryAttempt
            )
        }
    }

    private func scheduleSaturationRetry(
        agentID: String,
        confirmation: PromptLineTurnConfirmation,
        requiredRevision: UInt64?,
        attempt: Int
    ) {
        guard attempt < Self.maximumSaturationRetryAttempts else { return }
        let key = SaturationRetryKey(agentID: agentID, confirmationIdentifier: confirmation.identifier)
        saturationRetryTasksByConfirmation.removeValue(forKey: key)?.cancel()
        appendSaturationRetryKey(key)
        let clock = ContinuousClock()
        let delay = Duration.milliseconds(100 * (1 << min(attempt, 4)))
        saturationRetryTasksByConfirmation[key] = Task { [weak self] in
            await MainActor.run {
                TerminalMutationBus.shared.drainForBackpressure()
            }
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.saturationRetryReached(
                agentID: agentID,
                confirmation: confirmation,
                requiredRevision: requiredRevision,
                nextAttempt: attempt + 1
            )
        }
    }

    private func saturationRetryReached(
        agentID: String,
        confirmation: PromptLineTurnConfirmation,
        requiredRevision: UInt64?,
        nextAttempt: Int
    ) async {
        let key = SaturationRetryKey(agentID: agentID, confirmationIdentifier: confirmation.identifier)
        saturationRetryTasksByConfirmation.removeValue(forKey: key)
        removeSaturationRetryKey(key)
        await deliverVerifiedTurn(
            agentID: agentID,
            confirmation: confirmation,
            requiredRevision: requiredRevision,
            saturationRetryAttempt: nextAttempt
        )
    }

    private func hasDeliveredConfirmation(agentID: String, identifier: UInt64) -> Bool {
        deliveredConfirmationIdentifiersByAgentID[agentID]?.contains(identifier) == true
    }

    private func markDeliveredConfirmation(agentID: String, identifier: UInt64) {
        if deliveredConfirmationIdentifiersByAgentID[agentID, default: []].insert(identifier).inserted {
            deliveredConfirmationOrderByAgentID[agentID, default: []].append(identifier)
        }
        var order = deliveredConfirmationOrderByAgentID[agentID, default: []]
        while order.count > Self.maximumRememberedDeliveredConfirmationsPerAgent {
            let retired = order.removeFirst()
            deliveredConfirmationIdentifiersByAgentID[agentID]?.remove(retired)
        }
        deliveredConfirmationOrderByAgentID[agentID] = order
    }

    private func beginDeliveringConfirmation(agentID: String, identifier: UInt64) -> Bool {
        guard !hasDeliveredConfirmation(agentID: agentID, identifier: identifier),
              deliveringConfirmationIdentifiersByAgentID[agentID]?.contains(identifier) != true else {
            return false
        }
        deliveringConfirmationIdentifiersByAgentID[agentID, default: []].insert(identifier)
        return true
    }

    private func endDeliveringConfirmation(agentID: String, identifier: UInt64) {
        deliveringConfirmationIdentifiersByAgentID[agentID]?.remove(identifier)
        if deliveringConfirmationIdentifiersByAgentID[agentID]?.isEmpty == true {
            deliveringConfirmationIdentifiersByAgentID.removeValue(forKey: agentID)
        }
    }

    private func appendSaturationRetryKey(_ key: SaturationRetryKey) {
        if saturationRetryOrderByAgentID[key.agentID]?.contains(key.confirmationIdentifier) != true {
            saturationRetryOrderByAgentID[key.agentID, default: []].append(key.confirmationIdentifier)
        }
        var order = saturationRetryOrderByAgentID[key.agentID, default: []]
        while order.count > Self.maximumPendingSaturationRetriesPerAgent {
            let retiredIdentifier = order.removeFirst()
            let retiredKey = SaturationRetryKey(
                agentID: key.agentID,
                confirmationIdentifier: retiredIdentifier
            )
            saturationRetryTasksByConfirmation.removeValue(forKey: retiredKey)?.cancel()
        }
        saturationRetryOrderByAgentID[key.agentID] = order
    }

    private func removeSaturationRetryKey(_ key: SaturationRetryKey) {
        saturationRetryOrderByAgentID[key.agentID]?.removeAll { $0 == key.confirmationIdentifier }
        if saturationRetryOrderByAgentID[key.agentID]?.isEmpty == true {
            saturationRetryOrderByAgentID.removeValue(forKey: key.agentID)
        }
    }

    /// Verifies process identity fresh for every delivery. Deliveries happen
    /// at most once per completed turn, so re-reading the process argv is a
    /// single bounded lookup; caching identity across turns would let a
    /// reused PID or an exec'd replacement impersonate the agent.
    private func verifiedDefinition(
        foregroundPID: Int,
        agentID: String
    ) async -> CmuxTaskManagerCodingAgentDefinition? {
        let task: Task<CmuxTaskManagerCodingAgentDefinition?, Never>
        if inFlightPID == foregroundPID, let inFlightVerification {
            task = inFlightVerification
        } else {
            inFlightVerification?.cancel()
            task = Task.detached(priority: .utility) {
                CmuxTopProcessSnapshot.promptAgentDefinition(foregroundPID: foregroundPID)
            }
            inFlightPID = foregroundPID
            inFlightVerification = task
        }

        let definition = await task.value
        if inFlightPID == foregroundPID {
            inFlightPID = nil
            inFlightVerification = nil
        }
        return definition?.id == agentID ? definition : nil
    }

    /// Resolves the surface's current owner and foreground process. Live
    /// terminals move between workspaces (and into the Dock) without surface
    /// recreation, so the workspace captured at tee install time is only a
    /// lookup hint; delivery must follow the surface's current workspace.
    @MainActor
    private static func currentTurnContext(
        surfaceID: UUID,
        preferredWorkspaceID: UUID
    ) -> (workspaceID: UUID, foregroundPID: Int)? {
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: surfaceID,
            preferredWorkspaceId: preferredWorkspaceID
        ),
              let terminal = located.workspace.terminalPanel(for: surfaceID),
              let foregroundPID = terminal.surface.foregroundProcessID() else {
            return nil
        }
        return (located.workspace.id, foregroundPID)
    }
}
