import Foundation
import Testing

@testable import CmuxAgentChat

@MainActor
private enum TranscriptAvailabilityTestPoller {
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

    static func waitUntil(iterations: Int = 400, _ condition: () async -> Bool) async -> Bool {
        for iteration in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return await condition()
    }
}

private actor TranscriptAvailabilityEventSource: ChatEventSource {
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

@Suite("ChatConversationStore transcript availability")
@MainActor
struct ChatConversationStoreTranscriptAvailabilityTests {
    private static nonisolated let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @Test("pending transcript history reloads when descriptor becomes available")
    func pendingTranscriptHistoryReloadsWhenDescriptorBecomesAvailable() async {
        let source = TranscriptAvailabilityEventSource(pages: [
            ChatHistoryPage(messages: [], hasMore: false, transcriptAvailability: .pending),
            ChatHistoryPage(
                messages: [Self.prose(seq: 1, text: "ready")],
                hasMore: false,
                transcriptAvailability: .available
            ),
        ])
        let store = ChatConversationStore(
            descriptor: Self.descriptor(transcriptAvailability: .pending),
            source: source,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { store.hasLoadedInitialHistory })
        #expect(store.transcriptAvailability == .pending)
        #expect(store.rows.isEmpty)

        await source.emit(.descriptorChanged(Self.descriptor(transcriptAvailability: .available)))

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { store.transcriptAvailability == .available })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil { await source.historyCallCount() >= 2 })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil { Self.snapshots(store.rows).count == 1 })
        #expect(store.transcriptAvailability == .available)
        #expect(Self.snapshots(store.rows).map(\.message.id) == ["m1"])
    }

    private static func descriptor(
        transcriptAvailability: ChatTranscriptAvailability
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            title: "Test",
            transcriptAvailability: transcriptAvailability
        )
    }

    private static func prose(seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .agent,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func snapshots(_ rows: [ChatTranscriptRow]) -> [ChatMessageRowSnapshot] {
        rows.compactMap {
            if case .message(let snapshot) = $0 { return snapshot }
            return nil
        }
    }
}
