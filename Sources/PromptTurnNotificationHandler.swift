import Foundation

/// Verifies prompt-boundary candidates against the live process before notifying.
struct PromptTurnNotificationHandler: Sendable {
    func handle(workspaceID: UUID, surfaceID: UUID, agentID: String) {
        Task {
            let definition = await Task.detached(priority: .utility) {
                CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
                    .matchingPromptAgentDefinition(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID,
                        agentID: agentID
                    )
            }.value
            guard let definition else { return }

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
    }
}
