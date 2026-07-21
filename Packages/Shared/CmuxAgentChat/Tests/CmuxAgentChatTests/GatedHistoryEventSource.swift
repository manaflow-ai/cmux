import Foundation

@testable import CmuxAgentChat

actor GatedHistoryEventSource: ChatEventSource {
    private let page: ChatHistoryPage
    private var released = false
    private var waiters: [CheckedContinuation<ChatHistoryPage, Never>] = []

    init(page: ChatHistoryPage) {
        self.page = page
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        guard !released else { return page }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume(returning: page) }
        waiters.removeAll()
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {}

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}
}
