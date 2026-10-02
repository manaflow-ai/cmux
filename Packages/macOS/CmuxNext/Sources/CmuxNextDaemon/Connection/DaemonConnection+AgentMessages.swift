import Foundation

/// Agent messages between agents (plans/feat-agent-rooms/DESIGN.md). The
/// daemon stores and delivers them; the app only turns them off or on.
extension DaemonConnection {
    /// Turns messages to the agent in terminal `terminal` (`term_…`) off or
    /// back on (`agent.message.receiving.set`). Off fails the agent's queued
    /// messages and makes later sends to it fail with "has messages disabled".
    public func setAgentMessagesReceiving(_ terminal: ResourceID, enabled: Bool) async throws {
        let fields: [String: JSONValue] = ["recipient": .string(terminal.rawValue), "enabled": .bool(enabled)]
        let key = "cmux-next-agent-messages-" + UUID().uuidString.lowercased()
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "agent.message.receiving.set", params: fields, idempotencyKey: key)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}
