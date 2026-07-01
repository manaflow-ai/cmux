import Foundation
import Testing

@testable import CmuxAgentChat

@MainActor
private enum PromptEchoPreviewPoller {
    static func waitUntil(iterations: Int = 400, _ condition: () -> Bool) async -> Bool {
        for iteration in 0..<iterations {
            if condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return condition()
    }
}

private actor PromptEchoSilentSendEventSource: ChatEventSource {
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

@MainActor
struct ChatConversationStorePromptEchoPreviewTests {
    private static nonisolated let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @Test("live preview suppresses a suffix copied from the latest multi-line user prompt")
    func livePreviewSuppressesPromptSuffix() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await PromptEchoPreviewPoller.waitUntil { store.isConnected })
        let user = Self.prose(seq: 0, role: .user, text: "hihiiii\ntell me a story")
        await source.emit(.appended([user]))
        #expect(await PromptEchoPreviewPoller.waitUntil { Self.messageIDs(store.rows) == [user.id] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "tell me a story")))
        #expect(await PromptEchoPreviewPoller.waitUntil { Self.messageIDs(store.rows) == [user.id] })

        let realPreview = Self.streamingMessage(text: "Once upon a time, a tiny terminal learned to listen.")
        await source.emit(.streamingProse(realPreview))
        #expect(await PromptEchoPreviewPoller.waitUntil { Self.messageIDs(store.rows) == [user.id, realPreview.id] })
    }

    @Test("live preview suppresses a suffix copied from a pending multi-line user prompt")
    func livePreviewSuppressesPendingPromptSuffix() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await PromptEchoPreviewPoller.waitUntil { store.isConnected })
        await store.send(text: "hi\ntell me a stiyr")
        #expect(await PromptEchoPreviewPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "tell me a stiyr")))
        #expect(await PromptEchoPreviewPoller.waitUntil {
            Self.snapshots(store.rows).isEmpty
                && Self.pendingItems(store.rows).map(\.text) == ["hi\ntell me a stiyr"]
        })

        let realPreview = Self.streamingMessage(text: "Once upon a time, a terminal started typing.")
        await source.emit(.streamingProse(realPreview))
        #expect(await PromptEchoPreviewPoller.waitUntil { Self.messageIDs(store.rows) == [realPreview.id] })
    }

    private static func makeStore(source: some ChatEventSource) -> ChatConversationStore {
        ChatConversationStore(
            descriptor: ChatSessionDescriptor(id: "session", agentKind: .claude, title: "Session"),
            source: source,
            now: { baseTime }
        )
    }

    private static func prose(seq: Int, role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: role,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func streamingMessage(text: String) -> ChatMessage {
        ChatMessage(
            id: "stream:session",
            seq: Int.max - 1,
            role: .agent,
            timestamp: baseTime.addingTimeInterval(1000),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func snapshots(_ rows: [ChatTranscriptRow]) -> [ChatMessageRowSnapshot] {
        rows.compactMap { row in
            if case .message(let snapshot) = row { return snapshot }
            return nil
        }
    }

    private static func pendingItems(_ rows: [ChatTranscriptRow]) -> [ChatPendingOutbound] {
        rows.compactMap { row in
            if case .pendingOutbound(let pending) = row { return pending }
            return nil
        }
    }

    private static func messageIDs(_ rows: [ChatTranscriptRow]) -> [String] {
        snapshots(rows).map(\.message.id)
    }
}
