import CmuxAgentSync

@MainActor
final class AgentGUIConnectionEventRelay {
    let events: AsyncStream<AgentSyncConnectionEvent>

    private let continuation: AsyncStream<AgentSyncConnectionEvent>.Continuation

    init() {
        let pair = AsyncStream<AgentSyncConnectionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
    }

    func yield(_ event: AgentSyncConnectionEvent) {
        continuation.yield(event)
    }
}
