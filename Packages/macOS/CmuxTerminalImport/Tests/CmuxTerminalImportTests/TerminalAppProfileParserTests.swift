import Testing
@testable import CmuxTerminalImport

@Suite("Terminal.app profile import")
struct TerminalAppProfileParserTests {
    let fixtures = TestFixtures()

    @Test("decodes archived font and colors from the default profile")
    func defaultProfile() throws {
        let settings = try TerminalAppProfileParser().parse(preferences: fixtures.plist("terminal-app.plist"))

        #expect(settings.profileName == "Imported")
        #expect(settings.fontName == "Menlo-Regular")
        #expect(settings.fontNameIsPostScript)
        #expect(settings.fontSize == 13)
        #expect(settings.colors.foreground == TerminalColor(hex: "#ffffff"))
        #expect(settings.colors.background == TerminalColor(hex: "#000000"))
        #expect(settings.colors.cursor == TerminalColor(hex: "#ff8000"))
        #expect(settings.colors.selectionBackground == TerminalColor(hex: "#808080"))
        #expect(settings.colors.palette.count == 16)
        #expect(settings.colors.palette[0] == TerminalColor(hex: "#000000"))
        #expect(settings.colors.palette[9] == TerminalColor(hex: "#ff1a1a"))
        #expect(abs((settings.backgroundOpacity ?? 0) - 0.85) < 0.0001)
        #expect(settings.cursorShape == .bar)
        #expect(settings.cursorBlink == true)
        #expect(settings.optionAsAlt == .both)
        #expect(settings.backgroundBlur == 10)
        #expect(settings.scrollbackLines == 50000)
        #expect(settings.unmapped.contains { $0.contains("Bold text color") })
    }

    @Test("a calibrated RGB color is converted, staying close to its components")
    func calibratedColor() throws {
        let settings = try TerminalAppProfileParser().parse(preferences: fixtures.plist("terminal-app.plist"))
        let red = try #require(settings.colors.palette[1])
        #expect(abs(Int(red.red) - 204) < 20)
        #expect(red.green < 50)
    }

    @Test("an untouched built-in default profile has nothing to import")
    func builtInProfile() throws {
        let preferences = try fixtures.plist("terminal-app-builtin.plist")
        #expect(throws: TerminalAppProfileParser.ParseError.builtInProfile("Basic")) {
            try TerminalAppProfileParser().parse(preferences: preferences)
        }
    }
}
