import Foundation

/// Debounces prompt candidates and verifies their exact foreground process before notifying.
actor PromptTurnNotificationHandler {
    private let workspaceID: UUID
    private let surfaceID: UUID

    private var latestRevisionByAgentID: [String: UInt64] = [:]
    private var debounceTasksByAgentID: [String: Task<Void, Never>] = [:]

    private var cachedForegroundPID: Int?
    private var cachedDefinition: CmuxTaskManagerCodingAgentDefinition?
    private var hasCachedIdentity = false
    private var inFlightPID: Int?
    private var inFlightVerification: Task<CmuxTaskManagerCodingAgentDefinition?, Never>?

    init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    deinit {
        for task in debounceTasksByAgentID.values {
            task.cancel()
        }
        inFlightVerification?.cancel()
    }

    /// Replaces the pending candidate for an agent with a newer detector revision.
    func update(
        agentID: String,
        revision: UInt64,
        confirmation: PromptLineTurnConfirmation?,
        deadline: ContinuousClock.Instant?
    ) {
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
        guard confirmation.confirmedTurnCount > 0,
              let foregroundPID = await Self.foregroundProcessID(
                  workspaceID: workspaceID,
                  surfaceID: surfaceID
              ),
              let definition = await verifiedDefinition(
                  foregroundPID: foregroundPID,
                  agentID: agentID
              ),
              await Self.foregroundProcessID(
                  workspaceID: workspaceID,
                  surfaceID: surfaceID
              ) == foregroundPID,
              latestRevisionByAgentID[agentID] == revision else {
            return
        }

        AgentNotificationDelivery().enqueue(
            workspaceID: workspaceID,
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
            pending: false
        )
    }

    private func verifiedDefinition(
        foregroundPID: Int,
        agentID: String
    ) async -> CmuxTaskManagerCodingAgentDefinition? {
        if hasCachedIdentity, cachedForegroundPID == foregroundPID {
            return cachedDefinition?.id == agentID ? cachedDefinition : nil
        }

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
            cachedForegroundPID = foregroundPID
            cachedDefinition = definition
            hasCachedIdentity = true
        }
        return definition?.id == agentID ? definition : nil
    }

    @MainActor
    private static func foregroundProcessID(workspaceID: UUID, surfaceID: UUID) -> Int? {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
              let terminal = workspace.terminalPanel(for: surfaceID) else {
            return nil
        }
        return terminal.surface.foregroundProcessID()
    }
}
