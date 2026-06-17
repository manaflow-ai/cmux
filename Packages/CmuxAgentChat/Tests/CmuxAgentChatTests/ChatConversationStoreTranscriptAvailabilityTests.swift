import Foundation
import Testing

@testable import CmuxAgentChat

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
            now: { Self.baseTime },
            idleSleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        )
        let runTask = Task { await store.run() }

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { store.hasLoadedInitialHistory })
        #expect(store.transcriptAvailability == .pending)
        #expect(store.rows.isEmpty)

        await source.emit(.descriptorChanged(Self.descriptor(transcriptAvailability: .available)))

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { store.transcriptAvailability == .available })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil { await source.historyCallCount() >= 2 })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil { Self.snapshots(store.rows).count == 1 })
        #expect(store.transcriptAvailability == .available)
        #expect(Self.snapshots(store.rows).map(\.message.id) == ["m1"])
        runTask.cancel()
        await runTask.value
    }

    @Test("pending transcript history retries without a descriptor event")
    func pendingTranscriptHistoryRetriesWithoutDescriptorEvent() async {
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
            now: { Self.baseTime },
            idleSleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        )
        let runTask = Task { await store.run() }

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { await source.historyCallCount() >= 2 })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil { store.transcriptAvailability == .available })
        #expect(Self.snapshots(store.rows).map(\.message.id) == ["m1"])
        runTask.cancel()
        await runTask.value
    }

    @Test("pending transcript history retries are bounded")
    func pendingTranscriptHistoryRetriesAreBounded() async {
        let source = TranscriptAvailabilityEventSource(pages: [
            ChatHistoryPage(messages: [], hasMore: false, transcriptAvailability: .pending),
        ])
        let store = ChatConversationStore(
            descriptor: Self.descriptor(transcriptAvailability: .pending),
            source: source,
            now: { Self.baseTime },
            idleSleep: { _ in await Task.yield() }
        )
        let runTask = Task { await store.run() }

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { await source.historyCallCount() >= 7 })
        let callsAfterRetryBudget = await source.historyCallCount()
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.historyCallCount() == callsAfterRetryBudget)
        runTask.cancel()
        await runTask.value
    }

    @Test("available transcript clears and retries when descriptor becomes pending")
    func availableTranscriptClearsAndRetriesWhenDescriptorBecomesPending() async {
        let source = TranscriptAvailabilityEventSource(pages: [
            ChatHistoryPage(
                messages: [Self.prose(seq: 1, text: "old")],
                hasMore: false,
                transcriptAvailability: .available
            ),
            ChatHistoryPage(messages: [], hasMore: false, transcriptAvailability: .pending),
            ChatHistoryPage(
                messages: [Self.prose(seq: 2, text: "new")],
                hasMore: false,
                transcriptAvailability: .available
            ),
        ])
        let store = ChatConversationStore(
            descriptor: Self.descriptor(transcriptAvailability: .available),
            source: source,
            now: { Self.baseTime },
            idleSleep: { _ in try? await Task.sleep(nanoseconds: 20_000_000) }
        )
        let runTask = Task { await store.run() }

        #expect(await TranscriptAvailabilityTestPoller.waitUntil { Self.snapshots(store.rows).map(\.message.id) == ["m1"] })

        await source.emit(.descriptorChanged(Self.descriptor(transcriptAvailability: .pending)))

        #expect(await TranscriptAvailabilityTestPoller.waitUntil(iterations: 2_000) {
            store.transcriptAvailability == .pending && store.rows.isEmpty
        })
        #expect(await TranscriptAvailabilityTestPoller.waitUntil(iterations: 5_000) {
            Self.snapshots(store.rows).map(\.message.id) == ["m2"]
        })
        #expect(store.transcriptAvailability == .available)
        runTask.cancel()
        await runTask.value
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
