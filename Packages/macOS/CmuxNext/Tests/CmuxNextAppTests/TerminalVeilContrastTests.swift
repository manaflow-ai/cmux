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

    /// The user's report (Nov 11): "colors are less rich than the ones in Ghostty". Terminal Theme
    /// and App Theme Monokai Classic over a picture: the veil is Monokai's own background, yet its
    /// pink-red (1, 9: 3.9:1), its black (0) and its bright black (8) were washed toward white.
    /// A color reads on the veil as well as on its own theme's background: nothing to raise, so
    /// the terminal draws the theme exactly as Ghostty does.
    @Test func aThemeOnAVeilOfItsOwnBackgroundIsDrawnAsGhosttyDrawsIt() {
        let monokai = GhosttyThemeColors(
            background: .init(r: 0x27, g: 0x28, b: 0x22), foreground: .init(r: 0xFD, g: 0xFF, b: 0xF1),
            palette: [0x272822, 0xF92672, 0xA6E22E, 0xE6DB74, 0xFD971F, 0xAE81FF, 0x66D9EF, 0xFDFFF1,
                      0x6E7066, 0xF92672, 0xA6E22E, 0xE6DB74, 0xFD971F, 0xAE81FF, 0x66D9EF, 0xFDFFF1].map {
                GhosttyThemeColors.RGB(r: UInt8($0 >> 16), g: UInt8(($0 >> 8) & 0xFF), b: UInt8($0 & 0xFF))
            },
            selectionBackground: nil, selectionForeground: nil, cursor: nil, backgroundOpacity: 1, backgroundBlur: 0)
        #expect(monokai.contrastLines(over: ThemeRGB(hex: 0x272822)) == [])
        // A veil a shade darker than the theme's background reads every color at least as well: nothing changes.
        #expect(monokai.contrastLines(over: ThemeRGB(hex: 0x232420)) == [])
    }

    /// On a veil that reads worse than its own background, a color is raised back to how it read
    /// there (at most 4.5:1), never past it: a theme's black stays black on a light veil.
    @Test func aColorIsRaisedOnlyBackToHowItReadsOnItsOwnBackground() {
        let lines = Self.rosePine.contrastLines(over: Self.latteVeil)
        #expect(!lines.contains { $0.hasPrefix("palette = 0=") })
        let own = ThemeRGB(hex: 0x191724)
        for line in lines {
            guard let index = line.split(separator: "=").dropFirst().first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  let i = Int(index), let raised = Self.color(line) else { continue }
            let c = Self.rosePine.palette[i]
            let original = ThemeRGB(r: c.r, g: c.g, b: c.b)
            #expect(raised.contrast(with: Self.latteVeil) >= min(4.5, original.contrast(with: own)))
        }
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
