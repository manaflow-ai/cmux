import Foundation

struct AgentChatObservationInFlight {
    let id: UUID
    let scope: AgentChatObservationScope
    let task: Task<Void, Never>
    var waiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timer: DispatchSourceTimer?)] = [:]

    var handle: AgentChatObservationHandle {
        AgentChatObservationHandle(id: id, task: task)
    }
}
