import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxAgentChatUI

@MainActor
struct ChatConversationStoreTests {
    @Test("selects a session, paginates history, and applies live updates")
    func sessionLifecycle() async throws {
        let source = FixtureChatSource()
        let store = ChatConversationStore(source: source, workspaceID: "workspace-1")
        store.start()

        try await waitUntil { store.connectionState == .connected }
        #expect(store.selectedSessionID == "session-1")
        #expect(store.messages.map(\.seq) == [2, 3])
        #expect(store.hasMoreHistory)

        store.loadOlder()
        try await waitUntil { !store.isLoadingOlder }
        #expect(store.messages.map(\.seq) == [1, 2, 3])
        #expect(!store.hasMoreHistory)

        source.emit(
            .appended([
                FixtureChatSource.message(
                    id: "agent-4",
                    seq: 4,
                    role: .agent,
                    text: "live"
                )
            ])
        )
        try await waitUntil { store.messages.contains { $0.id == "agent-4" } }
        #expect(store.messages.last?.id == "agent-4")
        store.stop()
    }

    @Test("local echo is replaced by the provider's acknowledged user row")
    func localEchoReconciliation() async throws {
        let source = FixtureChatSource()
        let store = ChatConversationStore(source: source)
        store.start()
        try await waitUntil { store.connectionState == .connected }

        store.send(text: "ship it")
        #expect(store.messages.last?.role == .user)
        #expect(store.pendingMessageIDs.count == 1)

        try await waitUntil { store.pendingMessageIDs.isEmpty }
        #expect(store.messages.filter { $0.role == .user }.count == 1)
        #expect(store.messages.last?.id == "user-ship-it")
        #expect(!store.isSending)
        store.stop()
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for conversation store state")
    }
}

private final class FixtureChatSource: @unchecked Sendable, ChatEventSource {
    private(set) var sentTexts: [String] = []
    private var continuation: AsyncStream<ChatSessionEvent>.Continuation?

    private let descriptor = ChatSessionDescriptor(
        id: "session-1",
        agentKind: .other("fixture"),
        title: "Fixture chat",
        workspaceID: "workspace-1",
        state: .idle
    )

    private let history: [ChatMessage] = [
        message(id: "user-1", seq: 1, role: .user, text: "first"),
        message(id: "agent-2", seq: 2, role: .agent, text: "second"),
        message(id: "agent-3", seq: 3, role: .agent, text: "third"),
    ]

    func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        [descriptor]
    }

    func session(sessionID: String) async throws -> ChatSessionDescriptor {
        descriptor
    }

    func createSession(harness: String?, workingDirectory: String?) async throws -> String {
        descriptor.id
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        let values: [ChatMessage]
        let hasMore: Bool
        if let beforeSeq {
            values = history.filter { $0.seq < beforeSeq }
            hasMore = values.contains { $0.seq == 1 } == false
        } else {
            values = Array(history.suffix(2))
            hasMore = true
        }
        return ChatHistoryPage(messages: Array(values.prefix(limit)), hasMore: hasMore)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func send(
        text: String,
        attachments: [ChatOutboundAttachment],
        sessionID: String
    ) async throws {
        sentTexts.append(text)
        emit(
            .appended([
                Self.message(
                    id: "user-ship-it",
                    seq: 4,
                    role: .user,
                    text: text
                )
            ])
        )
    }

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}

    func emit(_ event: ChatSessionEvent) {
        continuation?.yield(event)
    }

    static func message(id: String, seq: Int, role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: role,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }
}
