import Foundation

struct AgentChatObservationHandle: Sendable {
    let id: UUID
    let task: Task<Void, Never>
}
