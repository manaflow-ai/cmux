#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// The terminal's Jump to bottom and jump-to-last-sent pills take the terminal theme (Leo,
/// 2026-11-24: "the jump to bottom and jump to top buttons in terminal on ios have not been
/// themed"): a light Mac theme draws a light pill with dark text, not the old fixed dark gray.
@MainActor
@Suite struct TerminalPillLookTests {
    static func rgb(_ color: Color) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    @Test func aLightThemeDrawsALightPillWithDarkText() throws {
        let theme = try #require(CmuxMobileTerminalTheme(lines: ["background = #fdf6e3", "foreground = #657b83"]))
        let look = TerminalPillLook(theme: theme)
        #expect(Self.rgb(look.background) == (0xFD, 0xF6, 0xE3))
        #expect(Self.rgb(look.ink) == (0x65, 0x7B, 0x83))
    }

    @Test func aDarkThemeDrawsItsOwnColors() throws {
        let theme = try #require(CmuxMobileTerminalTheme(lines: ["background = #1e1e2e", "foreground = #cdd6f4"]))
        let look = TerminalPillLook(theme: theme)
        #expect(Self.rgb(look.background) == (0x1E, 0x1E, 0x2E))
        #expect(Self.rgb(look.ink) == (0xCD, 0xD6, 0xF4))
    }

    @Test func noThemeYetIsThePhonesTerminal() {
        let look = TerminalPillLook(theme: nil)
        #expect(Self.rgb(look.background) == Self.rgb(Color(uiColor: CmuxMobileGhosttyApp.background)))
        #expect(Self.rgb(look.ink) == Self.rgb(Color(uiColor: CmuxMobileGhosttyApp.foreground)))
    }
}
#endif
