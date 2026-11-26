import Foundation
import Testing
@testable import CmuxTerminalImport

@Suite("File-based terminal config import")
struct TextConfigParserTests {
    let fixtures = TestFixtures()
    let home = URL(fileURLWithPath: "/nonexistent-home", isDirectory: true)

    @Test("Alacritty TOML follows general.import and lets the main file win")
    func alacrittyTOML() throws {
        let parser = AlacrittyConfigParser(reader: DiskTerminalConfigFileReader(), homeDirectory: home)
        let settings = try #require(parser.parse(url: fixtures.url("alacritty/alacritty.toml")))

        #expect(settings.fontName == "Iosevka Term")
        #expect(settings.fontSize == 13.5)
        #expect(settings.colors.background == TerminalColor(hex: "#1a1b26"))
        #expect(settings.colors.foreground == TerminalColor(hex: "#c0caf5"))
        #expect(settings.colors.cursorText == TerminalColor(hex: "#1a1b26"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.colors.palette[8] == TerminalColor(hex: "#414868"))
        #expect(settings.cursorShape == .bar)
        #expect(settings.cursorBlink == true)
        #expect(settings.optionAsAlt == .left)
        #expect(settings.paddingLeft == 12)
        #expect(settings.paddingTop == 8)
        #expect(settings.backgroundOpacity == 0.9)
        #expect(settings.backgroundBlur == 20)
        #expect(settings.scrollbackLines == 50000)
        #expect(settings.unmapped.contains { $0.contains("window.decorations") })
    }

    @Test("legacy Alacritty YAML with bare hex colors")
    func alacrittyYAML() throws {
        let parser = AlacrittyConfigParser(reader: DiskTerminalConfigFileReader(), homeDirectory: home)
        let settings = try #require(parser.parse(url: fixtures.url("alacritty/alacritty.yml")))

        #expect(settings.fontName == "Fira Code")
        #expect(settings.fontSize == 12)
        #expect(settings.colors.background == TerminalColor(hex: "#282c34"))
        #expect(settings.colors.palette[1] == TerminalColor(hex: "#e06c75"))
        #expect(settings.cursorShape == .underline)
        #expect(settings.cursorBlink == false)
        #expect(settings.paddingLeft == 4)
        #expect(settings.scrollbackLines == 10000)
    }

    @Test("Kitty reads the included theme and reports includes it could not follow")
    func kitty() throws {
        let parser = KittyConfigParser(reader: DiskTerminalConfigFileReader(), homeDirectory: home)
        let settings = try #require(parser.parse(url: fixtures.url("kitty/kitty.conf")))

        #expect(settings.fontName == "JetBrains Mono")
        #expect(settings.fontSize == 14)
        #expect(settings.colors.background == TerminalColor(hex: "#1e1e2e"))
        #expect(settings.colors.cursorText == TerminalColor(hex: "#1e1e2e"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.colors.palette[15] == TerminalColor(hex: "#a6adc8"))
        #expect(settings.cursorShape == .bar)
        #expect(settings.cursorBlink == false)
        #expect(settings.optionAsAlt == .left)
        #expect(settings.paddingTop == 4)
        #expect(settings.paddingLeft == 8)
        #expect(settings.backgroundOpacity == 0.95)
        #expect(settings.backgroundBlur == 16)
        #expect(settings.unlimitedScrollback)
        #expect(settings.unmapped.contains { $0.contains("missing.conf") })
        #expect(settings.unmapped.contains { $0.contains("modify_font") })
    }

    @Test("Kitty font_family accepts the plain and family= forms")
    func kittyFontFamily() {
        #expect(KittyConfigParser.fontFamily("Fira Code") == "Fira Code")
        #expect(KittyConfigParser.fontFamily("family='Fira Code' style=Retina") == "Fira Code")
        #expect(KittyConfigParser.fontFamily("monospace") == nil)
    }

    @Test("WezTerm imports literal assignments and names the Lua logic it skipped")
    func wezTerm() throws {
        let settings = WezTermConfigParser().parse(source: try fixtures.text("wezterm/wezterm.lua"))

        #expect(settings.fontName == "Berkeley Mono")
        #expect(settings.fontSize == 15)
        #expect(settings.cursorShape == .bar)
        #expect(settings.cursorBlink == true)
        #expect(settings.backgroundOpacity == 0.8)
        #expect(settings.backgroundBlur == 30)
        #expect(settings.scrollbackLines == 20000)
        #expect(settings.optionAsAlt == .both)
        #expect(settings.paddingLeft == 10)
        #expect(settings.paddingRight == 10)
        #expect(settings.paddingTop == nil)
        #expect(settings.paddingBottom == 5)
        #expect(settings.colors.background == TerminalColor(hex: "#1f1f28"))
        #expect(settings.colors.cursor == TerminalColor(hex: "#c8c093"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.colors.palette[9] == TerminalColor(hex: "#e82424"))
        #expect(settings.unmapped.contains { $0.contains("Tokyo Night") })
        #expect(settings.unmapped.contains { $0.contains("0.5cell") })
        #expect(settings.unmapped.contains { $0.contains("computed in Lua: initial_cols") })
        #expect(settings.unmapped.contains { $0.contains("Lua logic") && $0.contains("font_size") && $0.contains("window_background_opacity") })
    }

    @Test("WezTerm return-table configs and font_with_fallback")
    func wezTermReturnTable() throws {
        let settings = WezTermConfigParser().parse(source: try fixtures.text("wezterm/return-table.lua"))
        #expect(settings.fontName == "Fira Code")
        #expect(settings.fontSize == 12.5)
        #expect(settings.cursorShape == .underline)
        #expect(settings.cursorBlink == false)
    }

    @Test("Warp theme colors")
    func warp() throws {
        let settings = WarpThemeParser().parse(source: try fixtures.text("warp/solarized.yaml"), profileName: "solarized.yaml")
        #expect(settings.colors.background == TerminalColor(hex: "#002b36"))
        #expect(settings.colors.palette[4] == TerminalColor(hex: "#268bd2"))
        #expect(settings.colors.palette[15] == TerminalColor(hex: "#fdf6e3"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.fontName == nil)
    }
}
