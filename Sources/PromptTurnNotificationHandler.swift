import CmuxTerminalCore
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
#if DEBUG
        cmuxDebugLog(
            "agent.prompt.deadline surface=\(surfaceID.uuidString.prefix(8)) " +
            "agent=\(agentID) revision=\(revision)"
        )
#endif
        guard latestRevisionByAgentID[agentID] == revision else {
#if DEBUG
            cmuxDebugLog("agent.prompt.drop reason=stale-before-pid agent=\(agentID) revision=\(revision)")
#endif
            return
        }
        debounceTasksByAgentID.removeValue(forKey: agentID)
        guard confirmation.confirmedTurnCount > 0 else {
#if DEBUG
            cmuxDebugLog("agent.prompt.drop reason=no-completed-turn agent=\(agentID) revision=\(revision)")
#endif
            return
        }
        guard let foregroundPID = await Self.foregroundProcessID(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ) else {
#if DEBUG
            cmuxDebugLog("agent.prompt.drop reason=no-foreground-pid agent=\(agentID) revision=\(revision)")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("agent.prompt.pid agent=\(agentID) revision=\(revision) pid=\(foregroundPID)")
#endif
        guard let definition = await verifiedDefinition(
            foregroundPID: foregroundPID,
            agentID: agentID
        ) else {
#if DEBUG
            cmuxDebugLog(
                "agent.prompt.drop reason=identity-mismatch agent=\(agentID) " +
                "revision=\(revision) pid=\(foregroundPID)"
            )
#endif
            return
        }
        guard await Self.foregroundProcessID(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ) == foregroundPID else {
#if DEBUG
            cmuxDebugLog("agent.prompt.drop reason=foreground-changed agent=\(agentID) revision=\(revision)")
#endif
            return
        }
        guard latestRevisionByAgentID[agentID] == revision else {
#if DEBUG
            cmuxDebugLog("agent.prompt.drop reason=stale-after-pid agent=\(agentID) revision=\(revision)")
#endif
            return
        }

        let delivered = AgentNotificationDelivery().enqueue(
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
#if DEBUG
        cmuxDebugLog(
            "agent.prompt.enqueue surface=\(surfaceID.uuidString.prefix(8)) " +
            "agent=\(agentID) revision=\(revision) delivered=\(delivered ? 1 : 0)"
        )
#endif
    }

    private func verifiedDefinition(
        foregroundPID: Int,
        agentID: String
    ) async -> CmuxTaskManagerCodingAgentDefinition? {
        if hasCachedIdentity, cachedForegroundPID == foregroundPID {
#if DEBUG
            cmuxDebugLog(
                "agent.prompt.identity pid=\(foregroundPID) requested=\(agentID) " +
                "detected=\(cachedDefinition?.id ?? "none") cached=1"
            )
#endif
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
#if DEBUG
        cmuxDebugLog(
            "agent.prompt.identity pid=\(foregroundPID) requested=\(agentID) " +
            "detected=\(definition?.id ?? "none") cached=0"
        )
#endif
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
