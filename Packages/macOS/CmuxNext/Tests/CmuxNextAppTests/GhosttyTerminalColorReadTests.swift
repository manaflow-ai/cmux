@testable import CmuxNextTerminal
import Testing

/// The Ghostty config's `selection-background` and `cursor-color` reach the theme (cx-wqn5): libghostty reads a
/// plain `TerminalColor` as a color, so carets and text selection can follow the config.
struct GhosttyTerminalColorReadTests {
    @Test @MainActor func aPlainSelectionColorIsRead() throws {
        let colors = try #require(GhosttyRuntime.themeColors(configText: "selection-background = #335577\n"))
        #expect(colors.selectionBackground == GhosttyThemeColors.RGB(r: 0x33, g: 0x55, b: 0x77))
    }

    @Test @MainActor func aPlainCursorColorIsRead() throws {
        let colors = try #require(GhosttyRuntime.themeColors(configText: "cursor-color = #ff8800\n"))
        #expect(colors.cursor == GhosttyThemeColors.RGB(r: 0xFF, g: 0x88, b: 0x00))
    }

    @Test @MainActor func aCellRelativeSelectionIsNoColor() throws {
        let colors = try #require(GhosttyRuntime.themeColors(configText: "selection-background = cell-foreground\n"))
        #expect(colors.selectionBackground == nil)
    }
}
