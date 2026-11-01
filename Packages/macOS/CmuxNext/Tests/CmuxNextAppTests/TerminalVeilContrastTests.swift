import CmuxNextDesignTokens
import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// Over a picture background with an App Theme, one App Theme veil covers the sidebar and the
/// terminals, and each terminal keeps its Terminal Theme's colors, raised to 4.5:1 against the veil
/// where they fall short. The user's report (Oct 31): Terminal Theme Rose Pine under App Theme
/// Catppuccin Latte over the Great Wave drew a muddy grey Rose Pine wash beside the light Latte
/// veil; without that wash, Rose Pine's light text is unreadable on the light veil.
@MainActor
@Suite(.serialized)
struct TerminalVeilContrastTests {
    private static let rosePine = GhosttyThemeColors(
        background: .init(r: 0x19, g: 0x17, b: 0x24), foreground: .init(r: 0xE0, g: 0xDE, b: 0xF4),
        palette: [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                  0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4].map {
            GhosttyThemeColors.RGB(r: UInt8($0 >> 16), g: UInt8(($0 >> 8) & 0xFF), b: UInt8($0 & 0xFF))
        },
        selectionBackground: nil, selectionForeground: nil, cursor: nil, backgroundOpacity: 1, backgroundBlur: 0)
    private static let latteVeil = ThemeRGB(hex: 0xEFF1F5)
    private static let mochaVeil = ThemeRGB(hex: 0x1E1E2E)

    private static func color(_ line: String) -> ThemeRGB? {
        guard let hex = line.split(separator: "#").last, let value = UInt32(hex, radix: 16) else { return nil }
        return ThemeRGB(hex: value)
    }

    @Test func aLightTerminalThemeIsRaisedToReadOnALightVeil() throws {
        let lines = Self.rosePine.contrastLines(over: Self.latteVeil)
        let foreground = try #require(lines.first { $0.hasPrefix("foreground = ") })
        let raised = try #require(Self.color(foreground))
        #expect(raised.contrast(with: Self.latteVeil) >= 4.5)
        // Its hue is kept: still bluish (Rose Pine's text), only darker.
        #expect(raised.blue >= raised.red)
        // Every palette entry that read under 4.5:1 gets a line, and each now reads.
        let palette = lines.filter { $0.hasPrefix("palette = ") }
        #expect(palette.count >= 8)
        for line in palette { #expect(try #require(Self.color(line)).contrast(with: Self.latteVeil) >= 4.5) }
        // The background stays the terminal theme's: the veil draws behind the cells.
        #expect(!lines.contains { $0.hasPrefix("background") })
    }

    @Test func colorsThatAlreadyReadAreKept() {
        let lines = Self.rosePine.contrastLines(over: Self.mochaVeil)
        #expect(!lines.contains { $0.hasPrefix("foreground = ") })
        // Rose Pine's black and its muted grey sit under 4.5:1 on Mocha; its bright colors do not.
        #expect(!lines.contains("palette = 3=#f6c177"))
    }

    @Test func aSurfaceConfigTakesTheRaisedColorsAndKeepsTheRest() throws {
        _ = GhosttyRuntime.shared  // ghostty_config_new requires ghostty_init
        let base = try #require(ghostty_config_new())
        defer { ghostty_config_free(base) }
        for line in ["background = #191724", "foreground = #e0def4", "palette = 3=#f6c177"] {
            line.withCString { ghostty_config_load_string(base, $0, UInt(line.utf8.count), "test") }
        }
        ghostty_config_finalize(base)
        let surface = try #require(GhosttyRuntime.surfaceConfig(base, lines: ["foreground = #3a3850"]))
        defer { ghostty_config_free(surface) }
        let colors = try #require(GhosttyRuntime.themeColors(of: surface, backgroundOpacity: 1))
        #expect(colors.foreground == .init(r: 0x3A, g: 0x38, b: 0x50))
        #expect(colors.background == .init(r: 0x19, g: 0x17, b: 0x24))
        #expect(colors.palette[3] == .init(r: 0xF6, g: 0xC1, b: 0x77))
        #expect(GhosttyRuntime.surfaceConfig(base, lines: []) == nil)
    }
}
