import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct ReactionTargetTests {
    @Test func aCommittedMessageWithTheOwnersIDTakesATapback() throws {
        var message = Fixtures.message(1, Fixtures.chief, "Status?")
        message.reactions = [Reaction(author: Fixtures.me, partIndex: 0, kind: .tapback(.like)),
                             Reaction(author: Fixtures.chief, partIndex: 0, kind: .tapback(.love))]
        let item = try #require(Fixtures.items([message]).first)
        let target = try #require(HomeReactionTarget(item: item, partIndex: 0, conversation: Fixtures.conversation,
                                                     me: Fixtures.me, isOnline: true))
        #expect(target.message == MessageID("msg_1"))
        #expect(target.chosen == [.like], "only my own tapbacks count as chosen")
        #expect(target.op(.like) == nil, "no op for a tapback I already gave")
        #expect(target.op(.laugh) == .addReaction(message: MessageID("msg_1"), conversation: Fixtures.conversation,
                                                  reaction: .tapback(.laugh), partIndex: 0))
    }

    @Test func noTargetWithoutAnIDOfflineForAPendingSendOrARetractedMessage() throws {
        let committed = try #require(Fixtures.items([Fixtures.message(1, Fixtures.chief, "Status?")]).first)
        var noID = committed
        noID.messageID = nil
        #expect(HomeReactionTarget(item: noID, partIndex: 0, conversation: Fixtures.conversation, me: Fixtures.me, isOnline: true) == nil,
                "the client never invents a message id")
        #expect(HomeReactionTarget(item: committed, partIndex: 0, conversation: Fixtures.conversation, me: Fixtures.me, isOnline: false) == nil)
        #expect(HomeReactionTarget(item: committed, partIndex: 3, conversation: Fixtures.conversation, me: Fixtures.me, isOnline: true) == nil)
        var retracted = committed
        retracted.isRetracted = true
        #expect(HomeReactionTarget(item: retracted, partIndex: 0, conversation: Fixtures.conversation, me: Fixtures.me, isOnline: true) == nil)
        let intent = HomeIntent(op: .sendMessage(conversation: Fixtures.conversation, parts: [.text("Hi")]))
        let pending = try #require(Fixtures.items([], pending: [PendingIntent(intent: intent)]).first)
        #expect(pending.messageID == nil)
        #expect(HomeReactionTarget(item: pending, partIndex: 0, conversation: Fixtures.conversation, me: Fixtures.me, isOnline: true) == nil)
    }

    @Test func theControllerResolvesAHitAndEmitsTheAddReactionIntent() throws {
        let c = Fixtures.controller(width: 628, height: 900)
        let messages = Fixtures.conversation(6)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        var emitted: [HomeIntent] = []
        c.onIntent = { emitted.append($0) }
        let hit = try #require(c.hits(in: CGRect(x: 0, y: 0, width: 628, height: 900)).last)
        #expect(c.reactionTarget(for: hit, isOnline: false) == nil)
        let target = try #require(c.reactionTarget(for: hit, isOnline: true))
        #expect(target.message == messages.last?.id)
        let intent = try #require(c.react(.love, to: target))
        #expect(emitted == [intent])
        #expect(intent.op == .addReaction(message: target.message, conversation: Fixtures.conversation,
                                          reaction: .tapback(.love), partIndex: hit.partIndex))
    }

    @Test func aMessagesAccessibilityElementResolvesToItsTarget() throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items(Fixtures.conversation(4)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let elements = c.accessibilityItems()
        let message = try #require(elements.last(where: { $0.item != nil }))
        #expect(c.reactionTarget(for: message, isOnline: true) != nil)
        let compose = try #require(elements.first(where: { $0.id == "compose" }))
        #expect(c.reactionTarget(for: compose, isOnline: true) == nil)
    }

    @Test func everyTapbackHasAGlyphAndALocalizedName() {
        #expect(Set(HomeReactionStyle().tapbacks) == Set(Reaction.Tapback.allCases))
        for tapback in Reaction.Tapback.allCases {
            #expect(!HomeReactionStyle().glyph(tapback).isEmpty)
            #expect(HomeReactionStyle().glyph(.tapback(tapback)) == HomeReactionStyle().glyph(tapback))
            #expect(!HomeReactionStyle().accessibilityName(tapback).isEmpty)
        }
        #expect(HomeReactionStyle().accessibilityName(.love) == "Heart")
    }
}
