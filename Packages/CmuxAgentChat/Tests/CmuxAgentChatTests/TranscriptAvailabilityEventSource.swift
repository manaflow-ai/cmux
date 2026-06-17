@testable import CmuxAgentChat

actor TranscriptAvailabilityEventSource: ChatEventSource {
    private var pages: [ChatHistoryPage]
    private var continuations: [Int: AsyncStream<ChatSessionEvent>.Continuation] = [:]
    private var continuationCounter = 0
    private var historyCalls = 0

    init(pages: [ChatHistoryPage]) {
        self.pages = pages
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        historyCalls += 1
        if pages.count > 1 {
            return pages.removeFirst()
        }
        return pages[0]
    }

    func historyCallCount() -> Int {
        historyCalls
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let id = continuationCounter
        continuationCounter += 1
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func emit(_ event: ChatSessionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {}

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}

    private func removeContinuation(_ id: Int) {
        continuations[id] = nil
    }
}
