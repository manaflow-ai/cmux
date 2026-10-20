public import Foundation

public struct AgentChatObservationInFlight {
    public let id: UUID
    public let scope: AgentChatObservationScope
    public let task: Task<Void, Never>
    public var waiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timer: (any DispatchSourceTimer)?)] = [:]

    public init(
        id: UUID,
        scope: AgentChatObservationScope,
        task: Task<Void, Never>,
        waiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timer: (any DispatchSourceTimer)?)] = [:]
    ) {
        self.id = id
        self.scope = scope
        self.task = task
        self.waiters = waiters
    }

    public var handle: AgentChatObservationHandle {
        AgentChatObservationHandle(id: id, task: task)
    }
}
