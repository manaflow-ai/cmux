import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// Per-token theme edits (cx-wqn5, `appearance.themeEdits`): a derived "Nord (custom)" that never
/// changes Nord itself. The config cmux hands Ghostty loads the theme, then its edits, so an edited
/// token wins; the edits are the theme's wherever it applies, a pair takes its variant's, a bad
/// entry is dropped with a diagnostic, and a previewed edit shows live.
@MainActor @Suite(.serialized) struct ThemeEditsTests {
    /// Where the terminal setting hears app notices: held for the whole test (its AppEvents hold it weakly).
    private let center = NotificationCenter()

    func make(_ json: String) async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-theme-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, url)
    }

    func follow(_ settings: SettingsController) -> TerminalThemeSetting {
        let terminal = TerminalThemeSetting.testing(backdropScope: ThemeScope(level: .room), center: center)
        terminal.reload = {}
        terminal.follow(settings)
        return terminal
    }

    @Test func aThemesEditsLoadAfterItAndOnlyForIt() async throws {
        let (settings, url) = try await make(#"""
        {"appearance": {"theme": "Nord", "themeEdits": {
          "Nord/background": "#101010", "Nord/4": "#88C0D0", "Nord/cursor": "#ffffff",
          "Dracula/0": "#000000", "Nord/glow": "#111111", "Nord/1": "red", "Nord": "#222222",
          "dark:Nord/2": "#333333", "Nord/3": "#ＡＡＡＡＡＡ"}}}
        """#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = follow(settings)
        defer { withExtendedLifetime(terminal) {} }
        let edits = GhosttyRuntime.themeEdits
        #expect(GhosttyRuntime.themeLines(GhosttyRuntime.themeOverride, isDark: true, edits: edits) == [
            "theme = Nord", "background = #101010", "cursor-color = #ffffff", "palette = 4=#88c0d0",
        ])
        // A space, workspace or terminal theme takes its own edits.
        #expect(GhosttyRuntime.themeLines("Dracula", isDark: true, edits: edits) == ["theme = Dracula", "palette = 0=#000000"])
        #expect(GhosttyRuntime.themeLines("Tokyo Night", isDark: true, edits: edits) == ["theme = Tokyo Night"])
        // Unknown tokens, bad colors and keys without a token are reported and dropped.
        let reported = settings.snapshot.diagnostics.map(\.path).filter { $0.hasPrefix("appearance.themeEdits.") }
        #expect(Set(reported) == ["appearance.themeEdits.Nord/glow", "appearance.themeEdits.Nord/1", "appearance.themeEdits.Nord",
                                  "appearance.themeEdits.dark:Nord/2", "appearance.themeEdits.Nord/3"])
    }

    @Test func aPairTakesTheEditsOfTheVariantInEffect() {
        let edits = ThemeEdits(["Nord": ["background": "#101010"], "Nord Light": ["background": "#fafafa"]])
        let pair = "light:Nord Light,dark:Nord"
        #expect(GhosttyRuntime.themeLines(pair, isDark: true, edits: edits) == ["theme = \(pair)", "background = #101010"])
        #expect(GhosttyRuntime.themeLines(pair, isDark: false, edits: edits) == ["theme = \(pair)", "background = #fafafa"])
    }

    @Test func aPreviewedEditShowsLiveAndEndingRevertsIt() async throws {
        let (settings, url) = try await make(#"{"appearance": {"theme": "Nord"}}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = follow(settings)
        defer { withExtendedLifetime(terminal) {} }
        #expect(GhosttyRuntime.themeEdits.isEmpty)
        let descriptor = try #require(SettingsSchema.descriptor(for: ["appearance", "themeEdits"]))
        #expect(settings.preview(descriptor, .object(["Nord/background": .string("#202020")])))
        for _ in 0..<200 where GhosttyRuntime.themeEdits.isEmpty { await Task.yield() }
        #expect(GhosttyRuntime.themeEdits.configLines(for: "Nord") == ["background = #202020"])
        settings.endPreview()
        for _ in 0..<200 where !GhosttyRuntime.themeEdits.isEmpty { await Task.yield() }
        #expect(GhosttyRuntime.themeEdits.isEmpty)
    }
}
