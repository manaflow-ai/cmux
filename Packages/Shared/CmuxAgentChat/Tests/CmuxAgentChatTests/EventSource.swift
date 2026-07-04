@testable import CmuxAgentChat

actor EventSource: ChatEventSource {
    private var continuation: AsyncStream<ChatSessionEvent>.Continuation?

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: [], hasMore: false)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func emit(_ event: ChatSessionEvent) {
        continuation?.yield(event)
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {}
    func interrupt(sessionID: String, hard: Bool) async throws {}
    func answer(optionIndex: Int, sessionID: String) async throws {}
}
