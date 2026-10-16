import Testing
@testable import CmuxTerminalImport

@Suite("iTerm2 profile import")
struct ITerm2ProfileParserTests {
    let fixtures = TestFixtures()

    @Test("reads the default profile's font, colors, cursor, Option key, margins and transparency")
    func defaultProfile() throws {
        let settings = try ITerm2ProfileParser().parse(preferences: fixtures.plist("iterm2.plist"))

        #expect(settings.profileName == "Work")
        #expect(settings.fontName == "JetBrainsMono-Regular")
        #expect(settings.fontNameIsPostScript)
        #expect(settings.fontSize == 14.5)
        #expect(settings.colors.foreground == TerminalColor(hex: "#e6e6e6"))
        #expect(settings.colors.background == TerminalColor(hex: "#1a1a1a"))
        #expect(settings.colors.selectionBackground == TerminalColor(hex: "#336699"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.colors.palette[0] == TerminalColor(hex: "#0000ff"))
        #expect(settings.colors.palette[15] == TerminalColor(hex: "#ff0000"))
        #expect(settings.lightColors == nil)
        #expect(settings.cursorShape == .bar)
        #expect(settings.cursorBlink == false)
        #expect(settings.optionAsAlt == .left)
        #expect(settings.paddingLeft == 10)
        #expect(settings.paddingTop == 6)
        #expect(abs((settings.backgroundOpacity ?? 0) - 0.8) < 0.0001)
        #expect(settings.backgroundBlur == 12)
        #expect(settings.scrollbackLines == 100000)
        #expect(settings.unmapped.contains { $0.contains("Line spacing") })
    }

    @Test("converts Display P3 components to sRGB")
    func displayP3Conversion() throws {
        let settings = try ITerm2ProfileParser().parse(preferences: fixtures.plist("iterm2.plist"))
        let blue = try #require(settings.colors.palette[4])
        // P3 pure blue sits outside sRGB; after clamping it stays a saturated blue.
        #expect(blue.blue == 255)
        #expect(blue.red == 0)
    }

    @Test("separate light and dark colors become two schemes")
    func splitColors() throws {
        let settings = try ITerm2ProfileParser().parse(preferences: fixtures.plist("iterm2-split.plist"))
        #expect(settings.profileName == "Split")
        #expect(settings.colors.background == TerminalColor(hex: "#000000"))
        #expect(settings.lightColors?.background == TerminalColor(hex: "#ffffff"))
        #expect(settings.unlimitedScrollback)
    }

    @Test("preferences without profiles are rejected")
    func noProfiles() {
        #expect(throws: ITerm2ProfileParser.ParseError.noProfiles) {
            try ITerm2ProfileParser().parse(preferences: [:])
        }
    }
}
