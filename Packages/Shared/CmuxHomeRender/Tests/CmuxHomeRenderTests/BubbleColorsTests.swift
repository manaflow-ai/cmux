import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Per-chat bubble colours (user 2026-10-28: "make it configurable to change the bg/text color
/// ... for imessage chat UI, configurable per chat"). A chosen fill draws flat, its text reads
/// on it unless the person chose the text too, and no choice leaves the default look as it is.
@MainActor
@Suite struct BubbleColorsTests {
    static let light = HomePalette.Theme(background: .gray255(255), foreground: .gray255(29),
                                         accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21))
    static let dark = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230),
                                        accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))

    static func palettes() -> [(String, HomePalette)] {
        [("light", light), ("dark", dark)].flatMap { name, theme in
            [("\(name) iMessage", HomePalette.iMessageStyled(theme)), ("\(name) theme", HomePalette.themeStyled(theme))]
        }
    }

    @Test func noChoiceKeepsTheDefaultLook() {
        for (name, p) in Self.palettes() {
            #expect(p.applying(HomeBubbleColors()) == p, "\(name): an empty choice changed the palette")
        }
    }

    /// Yellow and dark navy: one needs black text, the other white.
    @Test(arguments: ["#FFD60A", "#1C2A4A", "#34C759", "#FF2D55"])
    func sentFillGetsReadableText(_ hex: String) throws {
        let fill = try #require(HomeColor(hex: hex))
        for (name, p) in Self.palettes() {
            let q = p.applying(HomeBubbleColors(sent: fill))
            #expect(q.outgoingGradient.allSatisfy { $0.color == fill }, "\(name) \(hex): sent fill not flat")
            #expect(q.outgoingText.contrast(with: fill) >= 3, "\(name) \(hex): sent text \(q.outgoingText.contrast(with: fill)):1")
            #expect(q.caret == fill, "\(name) \(hex): caret follows the sent colour")
        }
    }

    @Test func chosenTextIsKeptAsChosen() throws {
        let fill = try #require(HomeColor(hex: "#FFD60A")), ink = try #require(HomeColor(hex: "#5856D6"))
        for (name, p) in Self.palettes() {
            let q = p.applying(HomeBubbleColors(sent: fill, sentText: ink, received: fill, receivedText: ink))
            #expect(q.outgoingText == ink, "\(name): sent text replaced")
            #expect(q.incomingText == ink, "\(name): received text replaced")
        }
    }

    @Test(arguments: ["#FFD60A", "#1C2A4A", "#E5E5EA", "#3A3A3C"])
    func receivedFillGetsReadableTextAndTheComposerKeepsItsOwn(_ hex: String) throws {
        let fill = try #require(HomeColor(hex: hex))
        for (name, p) in Self.palettes() {
            let q = p.applying(HomeBubbleColors(received: fill))
            #expect(q.incomingBubble == fill, "\(name) \(hex): received fill")
            #expect(q.incomingText.contrast(with: fill) >= HomePalette.minimumTextContrast,
                    "\(name) \(hex): received text \(q.incomingText.contrast(with: fill)):1")
            #expect(q.composeText == p.incomingText, "\(name) \(hex): the composer's text moved with the bubbles")
            #expect(q.outgoingGradient == p.outgoingGradient, "\(name) \(hex): sent bubbles changed")
        }
    }

    @Test func aChatsColorsGoOverTheDefaultForEveryChat() throws {
        let green = try #require(HomeColor(hex: "#34C759")), black = try #require(HomeColor(hex: "000000"))
        let chat = HomeBubbleColors(sent: green)
        let all = HomeBubbleColors(sent: black, received: black)
        let merged = chat.over(all)
        #expect(merged.sent == green)
        #expect(merged.received == black)
    }

    @Test func hexRoundTripsThroughJSON() throws {
        let colors = HomeBubbleColors(sent: HomeColor(hex: "#34c759"), receivedText: HomeColor(hex: "#FFF"))
        let data = try JSONEncoder().encode(colors)
        #expect(String(decoding: data, as: UTF8.self).contains("#34C759"))
        #expect(try JSONDecoder().decode(HomeBubbleColors.self, from: data) == colors)
        #expect(HomeColor(hex: "blue") == nil)
    }
}
