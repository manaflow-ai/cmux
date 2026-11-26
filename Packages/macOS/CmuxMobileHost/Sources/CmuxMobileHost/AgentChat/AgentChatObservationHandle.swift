public import Foundation

public struct AgentChatObservationHandle: Sendable {
    public let id: UUID
    public let task: Task<Void, Never>

    public init(
        id: UUID,
        task: Task<Void, Never>
    ) {
        self.id = id
        self.task = task
    }
}
