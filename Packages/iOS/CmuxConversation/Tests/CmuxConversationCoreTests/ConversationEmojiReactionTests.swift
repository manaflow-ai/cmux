import Foundation
import Testing
@testable import CmuxConversationCore

/// Custom emoji tapbacks (iOS 18+ "Add custom emoji reaction"): any single
/// emoji, carried on the wire as the emoji itself.
@Suite struct ConversationEmojiReactionTests {
    @Test func classicsKeepTheirWireNamesAndEmojiRoundTrip() {
        for classic in ConversationReaction.allCases {
            #expect(ConversationReaction(rawValue: classic.rawValue) == classic)
            #expect(classic.emoji == nil)
        }
        #expect(ConversationReaction.allCases.count == 6)
        for emoji in ["\u{1F525}", "\u{2764}\u{FE0F}", "\u{1F44F}\u{1F3FD}", "\u{1F1EF}\u{1F1F5}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "#\u{FE0F}\u{20E3}"] {
            let reaction = ConversationReaction(rawValue: emoji)
            #expect(reaction == .emoji(emoji))
            #expect(reaction?.rawValue == emoji)
        }
    }

    @Test func onlyOneEmojiIsAReaction() {
        for text in ["", "a", "fire", "1", "\u{00A9}", "\u{2764}", "\u{1F525}\u{1F525}", "\u{1F525} ", "e\u{0301}"] {
            #expect(ConversationReaction(rawValue: text) == nil, "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        #expect(ConversationReaction.isSingleEmoji("\u{00A9}\u{FE0F}"))
    }

    @Test func wireDecodingKeepsEmojiTapbacksAndDropsUnknownOnes() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let message = WireDecoding.message([
            "id": "m1", "senderId": "lc", "text": "hi",
            "reactions": [
                ["participantId": "a", "reaction": "heart"],
                ["participantId": "b", "reaction": "\u{1F525}"],
                ["participantId": "c", "reaction": "sparkle"],
            ],
        ], base: base)
        #expect(message?.reactions.map(\.reaction) == [.heart, .emoji("\u{1F525}")])
    }

    @Test func emojiTapbacksAreSpokenWithTheEmoji() {
        #expect(ConversationAccessibilityText.reactionPhrase(.emoji("\u{1F525}"), by: "Bo") == "Bo reacted with \u{1F525}")
        #expect(ConversationAccessibilityText.reactionPhrase(.emoji("\u{1F525}"), by: nil) == "You reacted with \u{1F525}")
        #expect(ConversationAccessibilityText.tapbackName(.emoji("\u{1F525}")) == "\u{1F525}")
    }

    @Test func recentsPutTheLastPickFirstThenFillWithDefaults() throws {
        let suite = "imet.recents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = ConversationReactionRecents(defaults: defaults)
        #expect(recents.emoji == ConversationReactionRecents.defaults)

        recents.record(.emoji("\u{1F680}"))
        recents.record(.heart)
        recents.record(.emoji("\u{1F525}"))
        #expect(recents.used == ["\u{1F525}", "\u{1F680}"])
        let shown = recents.emoji
        #expect(Array(shown.prefix(3)) == ["\u{1F525}", "\u{1F680}", "\u{1F602}"])
        #expect(shown.count == ConversationReactionRecents.limit && Set(shown).count == shown.count)

        for scalar in 0x1F600...0x1F60F { recents.record(.emoji(String(UnicodeScalar(scalar)!))) }
        #expect(recents.used.count == ConversationReactionRecents.limit)
        #expect(recents.used.first == "\u{1F60F}")
    }
}
