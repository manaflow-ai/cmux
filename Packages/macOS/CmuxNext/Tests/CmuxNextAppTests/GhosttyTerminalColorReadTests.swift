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

    /// The iPhone's terminals load the Mac's terminal theme as Ghostty itself writes it: every
    /// theme key with its effective value, the whole 256-entry palette, cell-relative and
    /// `bright` values, and nothing that is not part of the terminal theme.
    @Test @MainActor func thePhoneTerminalThemeIsEveryThemeKeyAndNothingElse() {
        let lines = GhosttyRuntime.phoneTerminalThemeLines(configText: """
            background = #2b0b3f
            foreground = #f9e79f
            palette = 1=#ff3864
            palette = 200=#010203
            cursor-color = cell-foreground
            bold-color = bright
            minimum-contrast = 1.2
            faint-opacity = 0.35
            font-family = Menlo
            command = /bin/zsh
            keybind = cmd+k=clear_screen
            """)
        let keys = Set(lines.compactMap { $0.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } })
        #expect(keys == GhosttyRuntime.phoneTerminalThemeKeys)
        #expect(lines.contains("background = #2b0b3f"))
        #expect(lines.contains("foreground = #f9e79f"))
        #expect(lines.contains("palette = 1=#ff3864"))
        #expect(lines.contains("palette = 200=#010203"))
        #expect(lines.filter { $0.hasPrefix("palette = ") }.count == 256)
        #expect(lines.contains("cursor-color = cell-foreground"))
        #expect(lines.contains("bold-color = bright"))
        #expect(lines.contains("minimum-contrast = 1.2"))
        #expect(lines.contains("faint-opacity = 0.35"))
        #expect(!lines.contains { $0.hasPrefix("font-family") || $0.hasPrefix("command") || $0.hasPrefix("keybind") })
    }

    /// A key the config leaves unset still goes, empty, so the phone resets it to Ghostty's default.
    @Test func unsetThemeKeysGoEmpty() {
        let lines = GhosttyRuntime.phoneTerminalThemeLines(serialized: "cursor-text = \nfont-size = 13\ncursor-color = #ff8800\n")
        #expect(lines == ["cursor-text =", "cursor-color = #ff8800"])
    }
}
