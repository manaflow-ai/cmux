public import Foundation

public struct AgentChatObservationHandle: Sendable {
    public let id: UUID
    public let task: Task<Void, Never>
}
