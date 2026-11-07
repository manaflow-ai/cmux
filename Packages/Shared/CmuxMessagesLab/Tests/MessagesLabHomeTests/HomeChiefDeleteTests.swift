import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Delete on my message in a Chief chat (https://github.com/manaflow-ai/cmux/issues/36019): the row leaves
/// the transcript at once, the owner retracts the message, and a reopened chat shows no row and no
/// "You unsent a message" note for it. Other chats offer no Delete for a committed message.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeChiefDeleteTests {
    static let me = HomeChiefRetryTests.me
    static let chief = HomeChiefRetryTests.chief

    private func projected(_ view: MessagesLabHomeView, _ id: ID) -> MessagesLabHome.Message? {
        view.projection.controller.store?.state.conversation.messages.first { $0.id == id }
    }

    @Test func deleteRemovesTheRowAtOnceRetractsItAndStaysGoneOnReopen() async throws {
        let (store, view) = await HomeChiefRetryTests().open(Self.chief)
        // A message I send now (the mock owner keeps it, as the real owner keeps every message).
        let key = IdempotencyKey("chief-delete-mine")
        _ = try await store.perform(.sendMessage(conversation: Self.chief, parts: [.text("delete me")]), key: key)
        await HomeRetrySendTests().until {
            store.transcript(for: Self.chief).contains { $0.key == key && $0.seq != nil && $0.messageID != nil }
        }
        view.projection.refresh()
        let item = try #require(view.projection.shown.first { $0.key == key })
        let canonical = try #require(item.messageID)
        let id = HomeMapping.id(item, aliases: view.projection.aliases)
        #expect(view.projection.canDeleteMessage(id))

        view.projection.deleteMessage(id)
        // At once, before the owner answers: the row is gone, and Delete is not offered again.
        #expect(projected(view, id)?.deletedAt != nil)
        #expect(!view.projection.canDeleteMessage(id))

        // The owner retracts it.
        await HomeRetrySendTests().until {
            store.transcript(for: Self.chief).contains { $0.messageID == canonical && $0.isRetracted }
        }
        view.projection.refresh()
        #expect(projected(view, id)?.deletedAt != nil)
        view.stop()

        // Reopened: no row, and no unsent note in its place.
        let reopened = MessagesLabHomeView(store: store, conversation: Self.chief, me: Self.me,
                                           wake: HomeRetrySendTests.NoWake())
        defer { reopened.stop() }
        reopened.projection.refresh()
        let again = try #require(reopened.projection.shown.first { $0.messageID == canonical })
        let shownAgain = try #require(projected(reopened, HomeMapping.id(again, aliases: reopened.projection.aliases)))
        #expect(shownAgain.deletedAt != nil, "a deleted Chief message draws no row (no \"unsent\" note)")
    }

    @Test func theChiefsMessagesAndOtherChatsOfferNoDelete() async throws {
        let (_, chiefView) = await HomeChiefRetryTests().open(Self.chief)
        defer { chiefView.stop() }
        let reply = try #require(chiefView.projection.shown.first { $0.author != Self.me && $0.seq != nil })
        #expect(!chiefView.projection.canDeleteMessage(HomeMapping.id(reply, aliases: chiefView.projection.aliases)))

        let (_, direct) = await HomeChiefRetryTests().open(ConversationID("conv_austin"))
        defer { direct.stop() }
        let mine = try #require(direct.projection.shown.first { $0.author == Self.me && $0.seq != nil })
        #expect(!direct.projection.canDeleteMessage(HomeMapping.id(mine, aliases: direct.projection.aliases)))
    }
}
