import CmuxNextDesign
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// ask-87d30da8e5: the iPhone gets the colors this Mac's chrome derives from, so its own
/// `ThemeTokens.derive` lands on the same palette.
@MainActor
@Suite struct ThemePhoneTests {
    @Test func thePhoneGetsTheChromeInputAsHex() {
        var input = ThemeInput.ghosttyDefault
        input.accent = .blue
        input.selectionBackground = ThemeRGB(hex: 0x585B70)
        let tokens = ThemeTokens.derive(from: input)
        let sent = ThemePhone.appearance(input: input, tokens: tokens, accentFollowsArt: false, tint: 0.6)
        #expect(sent.background == "#282c34")
        #expect(sent.foreground == "#ffffff")
        #expect(sent.palette.count == 16)
        #expect(sent.palette.first == "#1d1f21")
        #expect(sent.selectionBackground == "#585b70")
        #expect(sent.cursor == nil)
        #expect(sent.accent == "blue")
        #expect(sent.accentColor == nil)
        #expect(sent.wallpaperTintOpacity == 0.6)
    }

    /// Art Color: the accent the windows show (the art's hue) goes as the theme's own accent.
    @Test func artColorSendsTheShownAccent() {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        let sent = ThemePhone.appearance(input: .ghosttyDefault, tokens: tokens, accentFollowsArt: true, tint: 0)
        #expect(sent.accent == "art")
        #expect(sent.accentColor == ThemePhone.hex(tokens.accent))
    }
}
