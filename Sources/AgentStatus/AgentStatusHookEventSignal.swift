import CMUXAgentLaunch
import Foundation

/// Status-only meaning extracted from a semantic hook event.
struct AgentStatusHookEventSignal: Equatable, Sendable {
    private static let statusSignalField = "_cmux_agent_status_signal"

    let statusKey: String
    let lifecycle: AgentHibernationLifecycleState
    let observedAt: Date

    init?(event: WorkstreamEvent) {
        let source = event.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let statusKey = source == "claude" ? "claude_code" : source
        guard AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) else { return nil }

        guard let lifecycle = Self.explicitLifecycle(from: event.extraFieldsJSON) else { return nil }
        self.statusKey = statusKey
        self.lifecycle = lifecycle
        self.observedAt = event.receivedAt
    }

    private static func explicitLifecycle(
        from extraFieldsJSON: String?
    ) -> AgentHibernationLifecycleState? {
        guard let extraFieldsJSON,
              let data = extraFieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object[statusSignalField] as? String else {
            return nil
        }
        return AgentHibernationLifecycleState.parseCLIValue(rawValue)
    }
}
