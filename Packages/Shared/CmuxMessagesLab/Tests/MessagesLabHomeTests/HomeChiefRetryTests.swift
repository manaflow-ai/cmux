import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeChiefRetryTests {
    static let me = ParticipantID("user_me")
    static let chief = ConversationID("conv_chief")

    func open(_ conversation: ConversationID) async -> (HomeStore, MessagesLabHomeView) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await HomeRetrySendTests().until { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        let view = MessagesLabHomeView(store: store, conversation: conversation, me: Self.me,
                                       wake: HomeRetrySendTests.NoWake())
        view.projection.refresh()
        return (store, view)
    }

    @Test func chiefRetryRequiresCapabilityAndForwardsCanonicalID() async throws {
        let (_, view) = await open(Self.chief)
        defer { view.stop() }
        let item = try #require(view.projection.shown.first { $0.author == Self.me && $0.seq != nil })
        let id = HomeMapping.id(item, aliases: view.projection.aliases)
        #expect(!view.projection.canRetryChiefTurn(id))
        var retried: MessageID?
        view.onChiefRetry = { retried = $0 }
        #expect(view.projection.canRetryChiefTurn(id))
        view.projection.retryChiefTurn(id)
        #expect(retried == item.messageID)
        #expect(!view.projection.canRetrySend(id))

        let reply = try #require(view.projection.shown.first { $0.author != Self.me })
        #expect(!view.projection.canRetryChiefTurn(HomeMapping.id(reply, aliases: view.projection.aliases)))
    }

    @Test func ordinaryConversationDoesNotOfferChiefRetry() async throws {
        let (_, view) = await open(ConversationID("conv_austin"))
        defer { view.stop() }
        view.onChiefRetry = { _ in Issue.record("ordinary chat invoked Chief retry") }
        let item = try #require(view.projection.shown.first { $0.author == Self.me && $0.seq != nil })
        let id = HomeMapping.id(item, aliases: view.projection.aliases)
        #expect(!view.projection.canRetryChiefTurn(id))
        view.projection.retryChiefTurn(id)
    }

    @Test func failedSendKeepsItsSeparateRetryAction() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        await HomeRetrySendTests().until { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.chief)
        let view = MessagesLabHomeView(store: store, conversation: Self.chief, me: Self.me,
                                       wake: HomeRetrySendTests.NoWake())
        defer { view.stop() }
        let key = IdempotencyKey("chief-retry-separation")
        await source.failNextSubmits(of: key, times: 1, with: .invalid("message_rejected"))
        _ = try? await store.perform(.sendMessage(conversation: Self.chief, parts: [.text("retry me")]), key: key)
        await HomeRetrySendTests().until {
            store.transcript(for: Self.chief).contains {
                guard $0.key == key else { return false }
                if case .notDelivered = $0.delivery { return true }
                return false
            }
        }
        view.projection.refresh()
        view.onChiefRetry = { _ in Issue.record("failed send invoked Chief retry") }
        let item = try #require(store.transcript(for: Self.chief).first { $0.key == key })
        let id = HomeMapping.id(item, aliases: view.projection.aliases)
        #expect(view.projection.canRetrySend(id))
        #expect(!view.projection.canRetryChiefTurn(id))
    }
}
