@testable import CmuxAgentChat

actor PromptEchoSilentSendEventSource: ChatEventSource {
    private var continuations: [Int: AsyncStream<ChatSessionEvent>.Continuation] = [:]
    private var nextContinuationID = 0

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: [], hasMore: false)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let id = nextContinuationID
        nextContinuationID += 1
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {}
    func interrupt(sessionID: String, hard: Bool) async throws {}
    func answer(optionIndex: Int, sessionID: String) async throws {}

    func emit(_ event: ChatSessionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: Int) {
        continuations[id] = nil
    }
}
