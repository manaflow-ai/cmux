import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A "Not Delivered" message of mine offers Try Again and Delete in its context menu
/// (plans/cmux-next/home-dm-group-chats/AUDIT.md item 10): Try Again sends it again through
/// `HomeStore.retry`, Delete drops it through `HomeStore.discardFailed`. Drives the projection
/// the transcript menu asks (`ChatIntents`) over a mock owner that refuses the first send.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeRetrySendTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let dm = ConversationID("conv_austin")

    func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition never held")
                return
            }
            await Task.yield()
        }
    }

    /// A store with the DM open, a view over it, and one send of `text` the owner refused.
    func failedSend(_ text: String) async -> (HomeStore, MessagesLabHomeView, IdempotencyKey) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        await until { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.dm)
        let view = MessagesLabHomeView(store: store, conversation: Self.dm, me: Self.me, wake: NoWake())
        let key = IdempotencyKey("send-\(text)")
        await source.failNextSubmits(of: key, times: 1, with: .invalid("message_rejected"))
        _ = try? await store.perform(.sendMessage(conversation: Self.dm, parts: [.text(text)]), key: key)
        await until { store.transcript(for: Self.dm).first { $0.key == key }?.delivery.isNotDelivered == true }
        view.projection.refresh()
        return (store, view, key)
    }

    func shownID(_ view: MessagesLabHomeView, _ key: IdempotencyKey) -> ID? {
        view.projection.shown.first { $0.key == key }.map { HomeMapping.id($0, aliases: view.projection.aliases) }
    }

    @Test func tryAgainSendsANotDeliveredMessage() async throws {
        let (store, view, key) = await failedSend("hello again")
        defer { view.stop() }
        let id = try #require(shownID(view, key))
        #expect(view.projection.canRetrySend(id))
        view.projection.retrySend(id)
        await until {
            store.transcript(for: Self.dm).contains { $0.parts == [.text("hello again")] && $0.delivery == .committed }
        }
        #expect(!store.transcript(for: Self.dm).contains { $0.delivery.isNotDelivered })
    }

    @Test func deleteDropsANotDeliveredMessage() async throws {
        let (store, view, key) = await failedSend("never mind")
        defer { view.stop() }
        let id = try #require(shownID(view, key))
        #expect(view.projection.canRetrySend(id))
        view.projection.deleteFailedSend(id)
        await until { !store.transcript(for: Self.dm).contains { $0.key == key } }
        #expect(!store.transcript(for: Self.dm).contains { $0.parts == [.text("never mind")] })
    }

    /// A delivered message, and anyone else's, offers neither.
    @Test func onlyMyFailedSendsOfferIt() async throws {
        let (store, view, _) = await failedSend("one")
        defer { view.stop() }
        let delivered = try #require(store.transcript(for: Self.dm).first { $0.delivery == .committed })
        #expect(!view.projection.canRetrySend(HomeMapping.id(delivered, aliases: view.projection.aliases)))
    }
}

private extension TranscriptItem.Delivery {
    var isNotDelivered: Bool {
        if case .notDelivered = self { true } else { false }
    }
}
