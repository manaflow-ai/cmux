public import Foundation

public struct AgentChatObservationInFlight {
    public let id: UUID
    public let scope: AgentChatObservationScope
    public let task: Task<Void, Never>
    public var waiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timer: (any DispatchSourceTimer)?)] = [:]

    public var handle: AgentChatObservationHandle {
        AgentChatObservationHandle(id: id, task: task)
    }
}
