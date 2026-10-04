import CmuxHomeCore
import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// A refused tapback (or any refused op other than a send) reaches the host
/// through `HomeStoreBinding.onRefusal`, so it can say why; before, the
/// binding dropped it and the tapback failed silently
/// (homerender-ios-host.md item 9). A refused send keeps its own path
/// (draft restore) and does not call the hook.
@MainActor
@Suite struct BindingRefusalTests {
    @Test func aRefusedReactionReachesTheHost() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        let id = ConversationID("conv_infra")
        try await until { store.me != nil && store.isOnline }
        await store.open(id)
        let me = try #require(store.me?.id)
        let message = try #require(store.transcript(for: id).last { $0.seq != nil })
        let controller = HomeController(conversation: id, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        controller.resize(to: CGSize(width: 628, height: 1041))
        let binding = HomeStoreBinding(store: store, controller: controller)
        defer { binding.stop() }
        var refused: [(HomeIntent, HomeRejection)] = []
        binding.onRefusal = { refused.append(($0, $1)) }
        await source.setOnline(false)
        try await until { !store.isOnline }
        let messageID = try #require(message.messageID)
        let intent = HomeIntent(op: .addReaction(message: messageID, conversation: id, reaction: .tapback(.love), partIndex: 0))
        controller.onIntent(intent)
        try await until { !refused.isEmpty }
        #expect(refused.first?.0.key == intent.key)
        store.stop()
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
        #expect(condition())
        if !condition() { throw CancellationError() }
    }
}
