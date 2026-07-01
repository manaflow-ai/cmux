import Foundation
import Testing

@testable import CmuxAgentChat

@MainActor
private func waitForPromptEchoPreview(iterations: Int = 2_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
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

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let user = Self.prose(seq: 0, role: .user, text: "hihiiii\ntell me a story")
        await source.emit(.appended([user]))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "tell me a story")))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id] })

        let realPreview = Self.streamingMessage(text: "Once upon a time, a tiny terminal learned to listen.")
        await source.emit(.streamingProse(realPreview))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id, realPreview.id] })
    }

    @Test("live preview suppresses a suffix copied from a pending multi-line user prompt")
    func livePreviewSuppressesPendingPromptSuffix() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "hi\ntell me a stiyr")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "tell me a stiyr")))
        #expect(await waitForPromptEchoPreview {
            Self.snapshots(store.rows).isEmpty
                && Self.pendingItems(store.rows).map(\.text) == ["hi\ntell me a stiyr"]
        })

        let realPreview = Self.streamingMessage(text: "Once upon a time, a terminal started typing.")
        await source.emit(.streamingProse(realPreview))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [realPreview.id] })
    }

    @Test("live preview suppresses a soft-wrapped suffix copied from a pending prompt")
    func livePreviewSuppressesSoftWrappedPendingPromptSuffix() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "please explain the design constraints clearly")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "design constraints\nclearly")))
        #expect(await waitForPromptEchoPreview {
            Self.snapshots(store.rows).isEmpty
                && Self.pendingItems(store.rows).map(\.text) == ["please explain the design constraints clearly"]
        })
    }

    @Test("live preview does not suppress text spanning explicit prompt line breaks")
    func livePreviewDoesNotSuppressAcrossPromptLines() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "A\nB\nC")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        let preview = Self.streamingMessage(text: "B C")
        await source.emit(.streamingProse(preview))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [preview.id] })
    }

    @Test("live preview is not cleared after real streaming text is accepted")
    func acceptedLivePreviewIsNotLaterClearedByPromptSuffix() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let user = Self.prose(seq: 0, role: .user, text: "respond with hello world")
        await source.emit(.appended([user]))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "hello")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["respond with hello world", "hello"] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "hello world")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["respond with hello world", "hello world"] })
    }

    @Test("queued prompts do not suppress the active turn live preview")
    func queuedPromptDoesNotSuppressActivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await source.emit(.stateChanged(.working(since: Self.baseTime)))
        #expect(await waitForPromptEchoPreview { store.agentState == .working(since: Self.baseTime) })
        await store.send(text: "queued follow-up\nsame suffix")
        #expect(await waitForPromptEchoPreview {
            Self.pendingItems(store.rows).contains { $0.delivery == .queued }
        })

        let preview = Self.streamingMessage(text: "same suffix")
        await source.emit(.streamingProse(preview))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [preview.id] })
    }

    @Test("live preview suppresses a bounded tail from a large prompt")
    func livePreviewSuppressesBoundedLargePromptTail() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let tail = "final visible line"
        let user = Self.prose(seq: 0, role: .user, text: String(repeating: "large paste\n", count: 800) + tail)
        await source.emit(.appended([user]))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id] })

        await source.emit(.streamingProse(Self.streamingMessage(text: tail)))
        #expect(await waitForPromptEchoPreview { Self.messageIDs(store.rows) == [user.id] })
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

    private static func proseTexts(_ rows: [ChatTranscriptRow]) -> [String] {
        snapshots(rows).compactMap { snapshot in
            if case .prose(let prose) = snapshot.message.kind { return prose.text }
            return nil
        }
    }
}
