import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationTextSizeTests {
    @Test func stepsThroughTheDynamicTypeSizesAndStopsAtTheEnds() {
        #expect(ConversationTextSize.large.stepped(by: 1) == .extraLarge)
        #expect(ConversationTextSize.large.stepped(by: -2) == .small)
        #expect(ConversationTextSize.large.stepped(by: 0) == .large)
        #expect(ConversationTextSize.extraSmall.stepped(by: -1) == .extraSmall)
        #expect(ConversationTextSize.accessibilityExtraExtraExtraLarge.stepped(by: 3) == .accessibilityExtraExtraExtraLarge)
        #expect(ConversationTextSize.extraExtraExtraLarge.stepped(by: 1) == .accessibilityMedium)
    }

    @Test func sizesAreOrderedByTheirBodyText() {
        let sizes = ConversationTextSize.allCases
        #expect(sizes.first == .extraSmall && sizes.last == .accessibilityExtraExtraExtraLarge)
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            #expect(smaller < larger)
            #expect(smaller.bodyPointSize < larger.bodyPointSize)
        }
        #expect(ConversationTextSize.standard.bodyPointSize == 17)
        #expect(!ConversationTextSize.extraExtraExtraLarge.isAccessibilitySize)
        #expect(ConversationTextSize.accessibilityMedium.isAccessibilitySize)
    }

    @Test func percentIsTheBodySizeOverTheBase() {
        #expect(ConversationTextSize.large.percent(of: .large) == 100)
        #expect(ConversationTextSize.extraLarge.percent(of: .large) == 112)
        #expect(ConversationTextSize.extraSmall.percent(of: .large) == 82)
    }

    @Test func savesByName() throws {
        let data = try JSONEncoder().encode(ConversationTextSize.accessibilityLarge)
        #expect(String(decoding: data, as: UTF8.self) == "\"accessibilityLarge\"")
        #expect(try JSONDecoder().decode(ConversationTextSize.self, from: data) == .accessibilityLarge)
    }
}
