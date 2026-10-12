import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// A theme's own accent (cx-wqn5.1): `<theme>/accent` in `appearance.themeEdits` gives that theme's
/// chrome its accent, over `appearance.accent`, and never reaches Ghostty's config (it is no
/// terminal color). A saved theme file carries it as `# cmux-accent = #rrggbb`, which Ghostty reads
/// as a comment and cmux reads back.
@MainActor @Suite(.serialized) struct ThemeAccentEditTests {
    static let red = ThemeRGB(hex: 0xBF616A)
    static let nord = ThemeInput(background: ThemeRGB(hex: 0x2E3440), foreground: ThemeRGB(hex: 0xD8DEE9),
                                 palette: (0..<16).map { [1, 9].contains($0) ? red : ThemeRGB(hex: 0x4C566A) })

    @Test func anAccentEditIsTheThemesAccentAndNoGhosttyLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-theme-accent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(##"{"appearance": {"theme": "Nord", "themeEdits": {"Nord/accent": "#BF616A", "Nord/4": "#88c0d0"}}}"##.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(!settings.snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.themeEdits.") })
        let edits = settings.snapshot.themeEdits
        #expect(edits.accent(for: "Nord") == "#bf616a")
        #expect(GhosttyRuntime.themeLines("Nord", isDark: true, edits: edits) == ["theme = Nord", "palette = 4=#88c0d0"])
    }

    @Test func theThemesAccentWinsOverAppearanceAccent() {
        // The palette's red is the edit's color, so `appearance.accent = red` is what the edit must give.
        let red = AppTheme.derive(from: { var input = Self.nord; input.accent = .red; return input }())
        for setting in [ThemeAccent.neutral, .theme, .cyan] {
            var input = Self.nord
            input.accent = setting
            input.accentColor = Self.red
            #expect(AppTheme.derive(from: input)[.accent] == red[.accent])
            // The terminal-theme tokens take it too (selection and focus), not the neutral fills.
            #expect(ThemeTokens.derive(from: input).accent == red[.accent])
        }
        #expect(ThemeTokens.derive(from: Self.nord).accent != red[.accent])
    }
}

extension ThemeFileSaveTests {
    @Test func aSavedAccentIsACommentLineTheCatalogReadsBack() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let file = try folders.save("Rose Pine Red", edits: ["accent": "#EB6F92", "background": "#101010"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\n# cmux-accent = #eb6f92\n"))
        // No key line Ghostty would read sets an accent.
        #expect(!text.split(separator: "\n").contains { !$0.hasPrefix("#") && $0.contains("accent") })
        #expect(folders.catalog().colors["Rose Pine Red"]?.accent == ThemeRGB(hex: 0xEB6F92))
        #expect(folders.catalog().colors["Rose Pine"]?.accent == nil)

        // An import keeps a file's accent; an accent alone is no theme.
        _ = try folders.importTheme("background = #000000\nforeground = #ffffff\n#cmux-accent=#00FF00\n", named: "Green")
        #expect(folders.catalog().colors["Green"]?.accent == ThemeRGB(hex: 0x00FF00))
        #expect(throws: GhosttyThemeFiles.Refusal.notATheme) { try folders.importTheme("# cmux-accent = #00ff00\n", named: "Bare") }
    }
}
