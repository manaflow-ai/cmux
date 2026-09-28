import Foundation
import Testing
@testable import CmuxFoundation

/// Golden files for `cmux themes export`: each agent format rendered from the
/// Catppuccin Mocha (dark) and Latte (light) Ghostty themes cmux bundles.
/// Regenerate a golden only after reviewing the new colors; the diff is the review.
@Suite("Agent theme export")
struct AgentThemeExportTests {
    @Test("Claude Code theme from a dark palette")
    func claudeDark() throws {
        let output = ClaudeCodeThemeRenderer().render(name: "Catppuccin Mocha (cmux)", palette: try Self.palette("catppuccin-mocha"))
        #expect(output == (try Self.golden("claude-catppuccin-mocha.json")))
    }

    @Test("Claude Code theme from a light palette")
    func claudeLight() throws {
        let output = ClaudeCodeThemeRenderer().render(name: "Catppuccin Latte (cmux)", palette: try Self.palette("catppuccin-latte"))
        #expect(output == (try Self.golden("claude-catppuccin-latte.json")))
    }

    @Test("OpenCode theme from a dark palette")
    func openCodeDark() throws {
        let output = OpenCodeThemeRenderer().render(appearances: .single(try Self.palette("catppuccin-mocha")))
        #expect(output == (try Self.golden("opencode-catppuccin-mocha.json")))
    }

    @Test("OpenCode theme from a light palette")
    func openCodeLight() throws {
        let output = OpenCodeThemeRenderer().render(appearances: .single(try Self.palette("catppuccin-latte")))
        #expect(output == (try Self.golden("opencode-catppuccin-latte.json")))
    }

    @Test("OpenCode theme from a light/dark pair uses dark and light values")
    func openCodePair() throws {
        let output = OpenCodeThemeRenderer().render(appearances: .pair(
            light: try Self.palette("catppuccin-latte"),
            dark: try Self.palette("catppuccin-mocha")
        ))
        #expect(output == (try Self.golden("opencode-catppuccin-pair.json")))
    }

    @Test("Exports are valid JSON with the documented top-level shape")
    func exportsParse() throws {
        let mocha = try Self.palette("catppuccin-mocha")
        let claude = try #require(try JSONSerialization.jsonObject(
            with: Data(ClaudeCodeThemeRenderer().render(name: "Quote \" and \\ slash", palette: mocha).utf8)
        ) as? [String: Any])
        #expect(claude["name"] as? String == "Quote \" and \\ slash")
        #expect(claude["base"] as? String == "dark")
        let overrides = try #require(claude["overrides"] as? [String: String])
        #expect(overrides.values.allSatisfy { GhosttyThemeRGB(hex: $0) != nil })

        let openCode = try #require(try JSONSerialization.jsonObject(
            with: Data(OpenCodeThemeRenderer().render(appearances: .single(mocha)).utf8)
        ) as? [String: Any])
        #expect(openCode["$schema"] as? String == OpenCodeThemeRenderer.schemaURL)
        let theme = try #require(openCode["theme"] as? [String: String])
        #expect(theme["background"] == "none")
    }

    @Test("Colors the user's config sets win over the theme file")
    func configOverridesTheme() {
        let theme = GhosttyThemeColors(parsing: """
        background = #000000
        palette = 1=#ff0000
        selection-background = #333333
        """)
        let merged = theme.overlaid(by: GhosttyThemeColors(parsing: """
        background = #101010
        palette = 2=#00ff00
        """))
        #expect(merged.background == GhosttyThemeRGB(hex: "#101010"))
        #expect(merged.palette[1] == GhosttyThemeRGB(hex: "#ff0000"))
        #expect(merged.palette[2] == GhosttyThemeRGB(hex: "#00ff00"))
        #expect(merged.selectionBackground == GhosttyThemeRGB(hex: "#333333"))
    }

    @Test("A palette fills unset colors with Ghostty's defaults")
    func paletteDefaults() {
        let palette = TerminalPalette(colors: GhosttyThemeColors(parsing: "palette = 4=#0000ff"))
        #expect(palette.background.hexString == "#282c34")
        #expect(palette.foreground.hexString == "#ffffff")
        #expect(palette.ansi[1].hexString == "#cc6666")
        #expect(palette.ansi[4].hexString == "#0000ff")
        #expect(palette.selectionBackground == palette.background.mixed(toward: palette.foreground, amount: 0.3))
        #expect(palette.isDark)
    }

    @Test(
        "Slugs are cmux-prefixed plain file names",
        arguments: [
            ("Catppuccin Mocha", "cmux-catppuccin-mocha"),
            ("cmux-mine", "cmux-mine"),
            ("Rosé Pine / Dawn", "cmux-rose-pine-dawn"),
            ("../../etc/passwd", "cmux-etc-passwd"),
        ]
    )
    func slugs(name: String, expected: String) throws {
        let slug = try #require(AgentThemeSlug(name: name))
        #expect(slug.value == expected)
        #expect(slug.fileName == expected + ".json")
    }

    @Test("Names with nothing to slug are rejected", arguments: ["", "  ", "..", "cmux", "日本語"])
    func emptySlugs(name: String) {
        #expect(AgentThemeSlug(name: name) == nil)
    }

    @Test("Theme directories follow each agent's config root")
    func themeDirectories() {
        let home = ["HOME": "/Users/test"]
        #expect(AgentThemeTarget.claude.themeDirectory(environment: home)?.path == "/Users/test/.claude/themes")
        #expect(AgentThemeTarget.opencode.themeDirectory(environment: home)?.path == "/Users/test/.config/opencode/themes")
        #expect(AgentThemeTarget.claude.themeDirectory(environment: home.merging(["CLAUDE_CONFIG_DIR": "/c"]) { $1 })?.path == "/c/themes")
        #expect(AgentThemeTarget.opencode.themeDirectory(environment: home.merging(["XDG_CONFIG_HOME": "/x"]) { $1 })?.path == "/x/opencode/themes")
        #expect(AgentThemeTarget(argument: "Claude-Code") == .claude)
        #expect(AgentThemeTarget(argument: "pi") == nil)
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return root.appendingPathComponent("AgentThemeExport", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private static func palette(_ name: String) throws -> TerminalPalette {
        let contents = try String(contentsOf: try fixtureURL(name + ".ghostty"), encoding: .utf8)
        return TerminalPalette(colors: GhosttyThemeColors(parsing: contents))
    }

    private static func golden(_ name: String) throws -> String {
        try String(contentsOf: try fixtureURL(name), encoding: .utf8)
    }
}
