import Foundation
import Testing
@testable import CmuxTerminalImport

@Suite("Malformed and extreme numbers")
struct MalformedNumberTests {
    let fixtures = TestFixtures()
    let themes = URL(fileURLWithPath: "/tmp/themes", isDirectory: true)

    @Test("overflowing and non-numeric Kitty values are dropped, huge ones clamped")
    func kitty() throws {
        let parser = KittyConfigParser(
            reader: DiskTerminalConfigFileReader(),
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home", isDirectory: true)
        )
        let settings = try #require(parser.parse(url: fixtures.url("kitty/malformed.conf")))
        #expect(settings.fontSize == nil)
        #expect(settings.scrollbackLines == nil)
        #expect(settings.backgroundBlur == nil)
        #expect(settings.backgroundOpacity == nil)
        #expect(settings.cursorBlink == nil)
        #expect(settings.paddingTop == 1e308)

        let plan = GhosttyImportMapper(fontResolver: StubFontResolver()).plan(for: settings, themeDirectory: themes)
        #expect(plan.settings.contains(.init(key: "window-padding-x", value: "\(GhosttyImportMapper.maximumPadding)")))
    }

    @Test("iTerm2 NaN, infinity and huge plist numbers never trap")
    func iTerm2() {
        let settings = ITerm2ProfileParser().parse(profile: [
            "Normal Font": "Menlo-Regular 1e999",
            "Transparency": Double.nan,
            "Scrollback Lines": 1e300,
            "Blur": true,
            "Blur Radius": Double.infinity,
            "Side Margins": "nan",
            "Cursor Type": 1e300,
        ])
        #expect(settings.fontSize == nil)
        #expect(settings.backgroundOpacity == nil)
        #expect(settings.scrollbackLines == Int(ConfigValue.integerLimit))
        #expect(settings.backgroundBlur == 2)
        #expect(settings.paddingLeft == nil)
        #expect(settings.cursorShape == nil)
    }

    @Test("the mapper clamps extreme values and skips non-finite ones")
    func mapper() {
        var settings = ImportedTerminalSettings(source: .kitty)
        settings.scrollbackLines = Int.max
        settings.backgroundBlur = Int.max
        settings.paddingLeft = .infinity
        settings.paddingTop = .nan
        settings.fontSize = .nan
        settings.backgroundOpacity = .nan
        let plan = GhosttyImportMapper(fontResolver: StubFontResolver()).plan(for: settings, themeDirectory: themes)
        #expect(plan.settings == [
            .init(key: "background-blur", value: "\(GhosttyImportMapper.maximumBlur)"),
            .init(key: "scrollback-limit", value: "\(Int.max)"),
        ])
    }

    @Test("TOML and Lua numbers too large for Int stay readable")
    func textNumbers() {
        #expect(ConfigValue.decimal("1e999") == nil)
        #expect(ConfigValue.decimal("nan") == nil)
        #expect(ConfigValue.int(.infinity) == nil)
        #expect(ConfigValue.number(1e20).string == "1e+20")
        let values = MiniTOMLParser().parse("[scrolling]\nhistory = 1e300\n")
        let settings = AlacrittyConfigParser(
            reader: DiskTerminalConfigFileReader(),
            homeDirectory: URL(fileURLWithPath: "/", isDirectory: true)
        ).settings(from: values, profileName: nil)
        #expect(settings.scrollbackLines == Int(ConfigValue.integerLimit))
        let lua = WezTermConfigParser().parse(source: "local config = {}\nconfig.scrollback_lines = 1e999\nconfig.macos_window_background_blur = 1e300\nreturn config\n")
        #expect(lua.scrollbackLines == nil)
        #expect(lua.backgroundBlur == Int(ConfigValue.integerLimit))
    }
}
