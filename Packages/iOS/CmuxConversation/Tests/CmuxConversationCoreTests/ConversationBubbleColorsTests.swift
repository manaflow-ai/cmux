import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationBubbleColorsTests {
    @Test func hexRoundTripsAndRejectsOtherText() throws {
        let green = try #require(ConversationColor(hex: "#34c759"))
        #expect(green.hex == "#34C759")
        #expect(ConversationColor(hex: "34C759") == green)
        #expect(ConversationColor(hex: "#34C75") == nil)
        #expect(ConversationColor(hex: "#GGGGGG") == nil)
        #expect(ConversationColor(hex: "blue") == nil)
    }

    @Test func aFillWithoutTextGetsTextThatReads() throws {
        let yellow = try #require(ConversationColor(hex: "#FFD60A"))
        let navy = try #require(ConversationColor(hex: "#1C2A4A"))
        let colors = ConversationBubbleColors(sent: yellow, received: navy)
        #expect(colors.resolvedSentText == .black)
        #expect(colors.resolvedReceivedText == .white)
        #expect(yellow.contrast(with: .black) >= 4.5 && navy.contrast(with: .white) >= 4.5)
        // A text colour the person set is kept as set.
        let set = ConversationBubbleColors(sent: yellow, sentText: navy)
        #expect(set.resolvedSentText == navy)
        // Nothing chosen: every role keeps the default.
        #expect(ConversationBubbleColors().isEmpty)
        #expect(ConversationBubbleColors().resolvedSentText == nil && ConversationBubbleColors().resolvedReceivedText == nil)
    }

    @Test func aPickedColourEqualsItselfAfterSaving() throws {
        let picked = ConversationColor(red: 0.123456, green: 0.5, blue: 0.987654)
        let read = try JSONDecoder().decode(ConversationColor.self, from: try JSONEncoder().encode(picked))
        #expect(read == picked)
    }

    @Test func savesAsHexAndSwatchesAreTheMacs() throws {
        let colors = ConversationBubbleColors(sent: ConversationColor(hex: "#34C759"))
        let json = String(decoding: try JSONEncoder().encode(colors), as: UTF8.self)
        #expect(json == ##"{"sent":"#34C759"}"##)
        #expect(try JSONDecoder().decode(ConversationBubbleColors.self, from: Data(json.utf8)) == colors)
        #expect(ConversationBubbleColors.sentSwatches.map(\.hex) == ["#0A84FF", "#34C759", "#AF52DE", "#FF2D55", "#FF9500", "#FFD60A", "#30B0C7", "#8E8E93"])
        #expect(ConversationBubbleColors.receivedSwatches.count == 7)
    }
}
