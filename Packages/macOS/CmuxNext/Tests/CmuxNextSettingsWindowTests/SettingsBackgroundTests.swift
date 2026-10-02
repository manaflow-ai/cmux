import AppKit
import CmuxNextDesign
@testable import CmuxNextSettingsWindow
import SwiftUI
import Testing

/// The Settings window stays opaque while the main window it was opened
/// from is see-through (clear glass at 60% was hard to read).
@MainActor @Suite(.serialized) struct SettingsBackgroundTests {
    @Test func settingsPaintsOpaqueOverATranslucentTheme() throws {
        var input = ThemeScope.app.input
        input.backgroundOpacity = 0.6
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        SettingsTheme.shared.follow(room)
        defer { SettingsTheme.shared.follow(.app) }
        #expect(SettingsTheme.shared.tokens.windowBackground.alpha < 1)
        let background = try #require(NSColor(SettingsStyle.background).usingColorSpace(.sRGB))
        #expect(background.alphaComponent == 1)
    }
}
