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

    @Test("next user turn clears stale live preview before echo suppression")
    func nextUserTurnClearsStaleLivePreviewBeforeEchoSuppression() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let first = Self.prose(seq: 0, role: .user, text: "first prompt")
        await source.emit(.appended([first]))
        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["first prompt", "valid preview"] })

        let second = Self.prose(seq: 1, role: .user, text: "next prompt tail")
        await source.emit(.appended([second]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["first prompt", "next prompt tail"] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "prompt tail")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["first prompt", "next prompt tail"] })
    }

    @Test("pending prompt echo does not clear accepted live preview")
    func pendingPromptEchoDoesNotClearAcceptedLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "current prompt")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        let echoedUser = Self.prose(seq: 0, role: .user, text: "current prompt")
        await source.emit(.appended([echoedUser]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["current prompt", "valid preview"] })
    }

    @Test("paste placeholder pending echo does not clear accepted live preview")
    func pastePlaceholderPendingEchoDoesNotClearAcceptedLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "line one\nline two\nline three")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        let echoedUser = Self.prose(seq: 0, role: .user, text: "[Pasted text #1 +3 lines]")
        await source.emit(.appended([echoedUser]))
        #expect(await waitForPromptEchoPreview {
            Self.proseTexts(store.rows) == ["[Pasted text #1 +3 lines]", "valid preview"]
        })
    }

    @Test("text attachment pending echo does not clear accepted live preview")
    func textAttachmentPendingEchoDoesNotClearAcceptedLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let outboundAttachment = ChatOutboundAttachment(data: Data([0x89]), format: .png)
        await store.send(text: "what is in this screenshot", attachments: [outboundAttachment])
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        let echoedAttachment = Self.attachment(seq: 0, hostPath: "/tmp/clipboard-image.png")
        let echoedText = Self.prose(seq: 1, role: .user, text: "what is in this screenshot")
        await source.emit(.appended([echoedAttachment, echoedText]))
        #expect(await waitForPromptEchoPreview {
            Self.proseTexts(store.rows) == ["what is in this screenshot", "valid preview"]
        })
    }

    @Test("attachment-only pending echo batch does not clear accepted live preview")
    func attachmentOnlyPendingEchoBatchDoesNotClearAcceptedLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let attachments = [
            ChatOutboundAttachment(data: Data([0x89]), format: .png),
            ChatOutboundAttachment(data: Data([0x50]), format: .png),
        ]
        await store.send(text: "", attachments: attachments)
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        await source.emit(.appended([
            Self.attachment(seq: 0, hostPath: "/tmp/clipboard-image-a.png"),
            Self.attachment(seq: 1, hostPath: "/tmp/clipboard-image-b.png"),
        ]))
        #expect(await waitForPromptEchoPreview {
            Self.proseTexts(store.rows) == ["valid preview"]
                && Self.pendingItems(store.rows).isEmpty
        })
    }

    @Test("mixed append batch clears preview for a real next user turn")
    func mixedAppendBatchClearsPreviewForRealNextUserTurn() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await store.send(text: "current prompt")
        #expect(await waitForPromptEchoPreview { Self.pendingItems(store.rows).count == 1 })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        let echoedUser = Self.prose(seq: 0, role: .user, text: "current prompt")
        let nextUser = Self.prose(seq: 1, role: .user, text: "next prompt")
        await source.emit(.appended([echoedUser, nextUser]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["current prompt", "next prompt"] })
    }

    @Test("replayed user append does not clear accepted live preview")
    func replayedUserAppendDoesNotClearAcceptedLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let user = Self.prose(seq: 0, role: .user, text: "already merged")
        await source.emit(.appended([user]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already merged"] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already merged", "valid preview"] })

        await source.emit(.appended([user]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already merged", "valid preview"] })
    }

    @Test("replayed agent append clears stale live preview")
    func replayedAgentAppendClearsStaleLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        let agent = Self.prose(seq: 0, role: .agent, text: "already committed")
        await source.emit(.appended([agent]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already committed"] })

        await source.emit(.streamingProse(Self.streamingMessage(text: "stale preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already committed", "stale preview"] })

        await source.emit(.appended([agent]))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["already committed"] })
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

    @Test("queued prompt match does not preserve stale live preview")
    func queuedPromptMatchDoesNotPreserveStaleLivePreview() async {
        let source = PromptEchoSilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await waitForPromptEchoPreview { store.isConnected })
        await source.emit(.stateChanged(.working(since: Self.baseTime)))
        #expect(await waitForPromptEchoPreview { store.agentState == .working(since: Self.baseTime) })
        await store.send(text: "queued duplicate")
        #expect(await waitForPromptEchoPreview {
            Self.pendingItems(store.rows).contains { $0.delivery == .queued }
        })

        await source.emit(.streamingProse(Self.streamingMessage(text: "valid preview")))
        #expect(await waitForPromptEchoPreview { Self.proseTexts(store.rows) == ["valid preview"] })

        let realUser = Self.prose(seq: 0, role: .user, text: "queued duplicate")
        await source.emit(.appended([realUser]))
        #expect(await waitForPromptEchoPreview {
            Self.proseTexts(store.rows) == ["queued duplicate"]
                && Self.pendingItems(store.rows).contains { $0.delivery == .queued }
        })
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

    private static func attachment(seq: Int, hostPath: String) -> ChatMessage {
        ChatMessage(
            id: "a\(seq)",
            seq: seq,
            role: .user,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: .attachment(ChatAttachment(media: .image, displayName: nil, hostPath: hostPath))
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
