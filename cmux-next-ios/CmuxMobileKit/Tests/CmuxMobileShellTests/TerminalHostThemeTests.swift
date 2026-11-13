@testable import CmuxMobileDesign
import Foundation
import Testing

/// The phone's terminals take their theme from the machine their session runs on: the Ghostty
/// lines its Mac sends (`appearance.terminal`), kept to the theme keys, with every key reset first.
@Suite struct TerminalHostThemeTests {
    static let macLines = [
        "background = #2B0B3F", "foreground = #f9e79f", "palette = 1=#ff3864", "palette = 200=#010203",
        "cursor-color = cell-foreground", "cursor-text =", "bold-color = bright", "minimum-contrast = 1.2",
    ]

    @Test func theMacsLinesAreTheTheme() throws {
        let theme = try #require(CmuxMobileTerminalTheme(lines: Self.macLines))
        #expect(theme.lines == Self.macLines)
        #expect(theme.background == "#2b0b3f")
        #expect(theme.foreground == "#f9e79f")
        #expect(theme.isDark)
    }

    /// Only theme keys with plain values: a phone never loads the Mac's command, files or keys.
    @Test func linesOutsideTheThemeAreDropped() throws {
        let theme = try #require(CmuxMobileTerminalTheme(lines: Self.macLines + [
            "command = /bin/sh -c 'curl x'", "config-file = /etc/passwd", "keybind = a=text:x",
            "foreground = $(whoami)", "background", "font-family = Menlo",
        ]))
        #expect(theme.lines == Self.macLines)
        #expect(CmuxMobileTerminalTheme(lines: ["palette = 0=#000000"]) == nil)
    }

    /// Every theme key (and `theme`, so no phone theme file loads) is reset before the Mac's lines.
    @Test func theConfigResetsEveryKeyBeforeTheMacsLines() throws {
        let theme = try #require(CmuxMobileTerminalTheme(lines: Self.macLines))
        let lines = theme.configText.split(separator: "\n").map(String.init)
        let resets = ["theme ="] + CmuxMobileTerminalTheme.keys.map { "\($0) =" }
        #expect(Array(lines.prefix(resets.count)) == resets)
        #expect(Array(lines.dropFirst(resets.count)) == Self.macLines)
    }

    /// A Mac that predates `terminal`: its chrome colors (its terminal theme unless it names an
    /// app theme) stand in, raw, not the phone's derived chrome palette.
    @Test func anOlderMacsChromeColorsStandIn() throws {
        let appearance = CmuxMobileMacAppearance(theme: .init(
            background: "#fafafa", foreground: "#101010", palette: (0..<16).map { String(format: "#%02x0000", $0) },
            selectionBackground: "#336699", cursor: "#ff8800"))
        let theme = try #require(CmuxMobileTerminalTheme(appearance: appearance))
        #expect(theme.background == "#fafafa")
        #expect(!theme.isDark)
        #expect(theme.lines.contains("palette = 15=#0f0000"))
        #expect(theme.lines.contains("cursor-color = #ff8800"))
        #expect(theme.lines.contains("selection-background = #336699"))
        var current = appearance
        current.terminal = Self.macLines
        #expect(CmuxMobileTerminalTheme(appearance: current)?.background == "#2b0b3f")
    }

    /// The frame from hostd decodes with its terminal lines; one without them still decodes.
    @Test func theAppearanceFrameCarriesTheTerminalLines() throws {
        let palette = (0..<8).map { "\"#0\($0)0000\"" }.joined(separator: ",")
        let frame = #"{"theme":{"background":"#000000","foreground":"#ffffff","palette":[\#(palette)],"accent":"neutral","background_opacity":1},"wallpaper":null,"terminal":["background = #2b0b3f","foreground = #f9e79f"]}"#
        let appearance = try #require(CmuxMobileMacAppearance.decode(Data(frame.utf8)))
        #expect(appearance.terminal == ["background = #2b0b3f", "foreground = #f9e79f"])
        let older = frame.replacingOccurrences(of: #","terminal":["background = #2b0b3f","foreground = #f9e79f"]"#, with: "")
        #expect(try #require(CmuxMobileMacAppearance.decode(Data(older.utf8))).terminal == nil)
    }
}
