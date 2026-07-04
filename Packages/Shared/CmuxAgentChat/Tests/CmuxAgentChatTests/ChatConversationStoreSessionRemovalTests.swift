import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatConversationStore session removal")
@MainActor
struct ChatConversationStoreSessionRemovalTests {
    private static nonisolated let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @Test("stale sessionRemoved does not end a newer focused descriptor")
    func staleSessionRemovedDoesNotEndNewerDescriptor() async {
        let source = EventSource()
        let store = ChatConversationStore(
            descriptor: ChatSessionDescriptor(
                id: "session-1",
                agentKind: .claude,
                title: "Test",
                state: .working(since: Self.baseTime),
                version: 6
            ),
            source: source,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        await source.emit(.sessionRemoved(version: 5))
        await Task.yield()

        #expect(store.agentState == .working(since: Self.baseTime))
    }

    @Test("stale live events do not revive removed focused descriptor")
    func staleLiveEventsDoNotReviveRemovedDescriptor() async {
        let source = EventSource()
        let store = ChatConversationStore(
            descriptor: Self.descriptor(state: .working(since: Self.baseTime), version: 5),
            source: source,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        await source.emit(.sessionRemoved(version: 6))
        #expect(await Self.waitUntil { store.agentState == ChatAgentState.ended })

        await source.emit(.stateChanged(.idle))
        await source.emit(.descriptorChanged(Self.descriptor(state: .idle, version: 6)))
        await Task.yield()
        #expect(store.agentState == ChatAgentState.ended)

        await source.emit(.descriptorChanged(Self.descriptor(state: .idle, version: 7)))
        #expect(await Self.waitUntil { store.agentState == ChatAgentState.idle })
    }

    @Test("sessionRemoved keeps the public descriptor state in sync")
    func sessionRemovedUpdatesPublicDescriptorState() async {
        let source = EventSource()
        let store = ChatConversationStore(
            descriptor: Self.descriptor(state: .working(since: Self.baseTime), version: 5),
            source: source,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        await source.emit(.sessionRemoved(version: 6))
        #expect(await Self.waitUntil { store.agentState == ChatAgentState.ended })

        #expect(store.descriptor.state == .ended)
        #expect(store.descriptor.version == 6)
    }

    @Test("unversioned sessionRemoved allows equal-version descriptor revival")
    func unversionedSessionRemovedAllowsEqualVersionDescriptorRevival() async {
        let source = EventSource()
        let store = ChatConversationStore(
            descriptor: Self.descriptor(state: .working(since: Self.baseTime), version: 5),
            source: source,
            now: { Self.baseTime }
        )
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await Self.waitUntil { store.isConnected })
        await source.emit(.sessionRemoved(version: Int.max))
        #expect(await Self.waitUntil { store.agentState == ChatAgentState.ended })
        #expect(store.descriptor.version == 5)

        await source.emit(.descriptorChanged(Self.descriptor(state: .idle, version: 5)))
        #expect(await Self.waitUntil { store.agentState == ChatAgentState.idle })
        #expect(store.descriptor.version == 5)
    }

    private static func descriptor(
        state: ChatAgentState,
        version: Int
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            title: "Test",
            state: state,
            version: version
        )
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
}
