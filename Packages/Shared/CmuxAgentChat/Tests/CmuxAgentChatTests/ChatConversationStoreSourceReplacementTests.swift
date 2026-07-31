import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatConversationStore source replacement")
@MainActor
struct ChatConversationStoreSourceReplacementTests {
    private static nonisolated let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    private static func descriptor(state: ChatAgentState = .idle) -> ChatSessionDescriptor {
        ChatSessionDescriptor(id: "session-1", agentKind: .claude, title: "Test", state: state)
    }

    private static func prose(seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .user,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func userProseTexts(_ rows: [ChatTranscriptRow]) -> [String] {
        rows.compactMap { row in
            guard case .message(let snapshot) = row,
                  snapshot.message.role == .user,
                  case .prose(let prose) = snapshot.message.kind
            else { return nil }
            return prose.text
        }
    }

    private static func waitUntil(
        iterations: Int = 400,
        _ condition: () -> Bool
    ) async -> Bool {
        for iteration in 0..<iterations {
            if condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return condition()
    }

    @Test("a stale initial history result is discarded after source replacement")
    func staleInitialHistoryResultIsDiscardedAfterSourceReplacement() async {
        let oldSource = GatedHistoryEventSource(
            page: ChatHistoryPage(messages: [Self.prose(seq: 0, text: "old history")], hasMore: false)
        )
        let newSource = FixtureChatEventSource(
            backlog: [Self.prose(seq: 0, text: "new history")]
        )
        let store = ChatConversationStore(
            descriptor: Self.descriptor(),
            source: oldSource,
            sourceIdentity: "old",
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        store.replaceSource(newSource, descriptor: Self.descriptor(), sourceIdentity: "new")
        await oldSource.release()

        #expect(await Self.waitUntil {
            Self.userProseTexts(store.rows) == ["new history"]
        })
    }

    @Test("unknown source identity still discards stale history after replacement")
    func unknownSourceIdentityStillDiscardsStaleHistoryAfterReplacement() async {
        let oldSource = GatedHistoryEventSource(
            page: ChatHistoryPage(messages: [Self.prose(seq: 0, text: "old history")], hasMore: false)
        )
        let newSource = FixtureChatEventSource(
            backlog: [Self.prose(seq: 0, text: "new history")]
        )
        let store = ChatConversationStore(
            descriptor: Self.descriptor(),
            source: oldSource,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        store.replaceSource(newSource, descriptor: Self.descriptor())
        await oldSource.release()

        #expect(await Self.waitUntil {
            Self.userProseTexts(store.rows) == ["new history"]
        })
    }

    @Test("source replacement accepts an equal-version fresh descriptor")
    func sourceReplacementAcceptsEqualVersionFreshDescriptor() async {
        let oldSource = FixtureChatEventSource()
        let newSource = FixtureChatEventSource()
        let store = ChatConversationStore(
            descriptor: Self.descriptor(state: .working(since: Self.baseTime)),
            source: oldSource,
            sourceIdentity: "old",
            now: { Self.baseTime }
        )

        store.replaceSource(newSource, descriptor: Self.descriptor(state: .idle), sourceIdentity: "new")

        #expect(store.agentState == .idle)
    }
}
