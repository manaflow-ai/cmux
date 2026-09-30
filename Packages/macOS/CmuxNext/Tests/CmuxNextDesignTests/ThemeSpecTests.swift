import Testing
@testable import CmuxNextDesign

/// Theme specs and the room > workspace > terminal precedence.
@Suite struct ThemeSpecTests {
    @Test func plainNameAppliesToBothAppearances() throws {
        let spec = try #require(ThemeSpec("  Nord "))
        #expect(spec.raw == "Nord")
        #expect(spec.name(isDark: true) == "Nord")
        #expect(spec.name(isDark: false) == "Nord")
        #expect(!spec.isConditional)
        #expect(spec.configLine(isDark: true) == "theme = Nord")
    }

    @Test func lightDarkPairInEitherOrder() throws {
        let pair = try #require(ThemeSpec("light:Rose Pine Dawn,dark:Rose Pine"))
        #expect(pair.name(isDark: false) == "Rose Pine Dawn")
        #expect(pair.name(isDark: true) == "Rose Pine")
        #expect(pair.isConditional)
        let reversed = try #require(ThemeSpec("dark: Nord , light: GitHub Light Default"))
        #expect(reversed.name(isDark: true) == "Nord")
        #expect(reversed.name(isDark: false) == "GitHub Light Default")
        // One side only: that theme in both appearances.
        #expect(ThemeSpec("dark:Nord")?.name(isDark: false) == "Nord")
    }

    @Test func refusesTextThatIsNotASpec() {
        for bad in ["", "   ", "Nord\ntheme = x", "a=b", "#Nord", "\"Nord\"", "sepia:Nord", "Nord,", String(repeating: "x", count: 201)] {
            #expect(ThemeSpec(bad) == nil, "\(bad)")
        }
    }

    @Test func precedenceIsTerminalWorkspaceRoomConfig() {
        let all = ThemeLayers.parsing(room: "Nord", workspace: "Vesper", terminal: "TokyoNight")
        #expect(all.effective(at: .terminal).spec?.raw == "TokyoNight")
        #expect(all.effective(at: .terminal).source == .terminal)
        #expect(all.effective(at: .workspace).spec?.raw == "Vesper")
        #expect(all.effective(at: .room).spec?.raw == "Nord")
        #expect(all.effective(at: .config).spec == nil)

        let roomOnly = ThemeLayers.parsing(room: "Nord", workspace: nil, terminal: nil)
        #expect(roomOnly.effective(at: .terminal).spec?.raw == "Nord")
        #expect(roomOnly.effective(at: .terminal).source == .room)

        let workspaceOnly = ThemeLayers.parsing(room: nil, workspace: "Vesper", terminal: nil)
        #expect(workspaceOnly.effective(at: .room).source == .config)
        #expect(workspaceOnly.effective(at: .terminal).spec?.raw == "Vesper")

        let none = ThemeLayers.parsing(room: nil, workspace: nil, terminal: nil)
        #expect(none.effective(at: .terminal).spec == nil)
        #expect(none.effective(at: .terminal).source == .config)
    }

    @Test func unparsableStoredTextFallsBack() {
        let layers = ThemeLayers.parsing(room: "Nord", workspace: "bad=value", terminal: "")
        #expect(layers.workspace == nil)
        #expect(layers.effective(at: .terminal).spec?.raw == "Nord")
        #expect(layers.own(.workspace) == nil)
        #expect(layers.own(.room)?.raw == "Nord")
    }
}
