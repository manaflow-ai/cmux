import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// One highlight color app-wide (user 2026-10-28: "make sure the highlight color across everything
/// in the app can be customized (and is consistent) based on the user's terminal theme"). The
/// terminal theme's `selection-background` is the default; `appearance.highlightColor` in cmux.json
/// (Settings > Appearance > Highlight Color) replaces it for the terminal itself, and so for every
/// page and text field, which read the terminal's selection color.
@MainActor @Suite(.serialized) struct HighlightColorTests {
    func make(_ json: String) async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-highlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, url)
    }

    func follow(_ settings: SettingsController) -> TerminalThemeSetting {
        let terminal = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        terminal.reload = {}
        terminal.follow(settings)
        return terminal
    }

    @Test func theOverrideBecomesTheTerminalsSelectionColor() async throws {
        let (settings, url) = try await make(##"{"appearance": {"theme": "Nord", "highlightColor": "#FF8800"}}"##)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = follow(settings)
        defer { withExtendedLifetime(terminal) {}; GhosttyRuntime.themeEdits = .none }
        #expect(GhosttyRuntime.themeEdits.highlight == "#ff8800")
        #expect(GhosttyRuntime.highlightLines(GhosttyRuntime.themeEdits.highlight) == ["selection-background = #ff8800"])
        #expect(settings.snapshot.diagnostics.filter { $0.path == "appearance.highlightColor" }.isEmpty)
    }

    @Test func unsetTheThemesOwnSelectionStays() async throws {
        let (settings, url) = try await make(##"{"appearance": {"theme": "Nord"}}"##)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = follow(settings)
        defer { withExtendedLifetime(terminal) {} }
        #expect(GhosttyRuntime.themeEdits.highlight == nil)
        #expect(GhosttyRuntime.highlightLines(nil).isEmpty)
    }

    /// The Settings color well can write an alpha; Ghostty's selection is opaque, so it is dropped.
    @Test func anAlphaIsDroppedAndABadValueIsReported() async throws {
        let (alpha, alphaURL) = try await make(##"{"appearance": {"highlightColor": "#33557780"}}"##)
        defer { try? FileManager.default.removeItem(at: alphaURL.deletingLastPathComponent()) }
        #expect(alpha.snapshot.highlightColor == "#335577")

        let (bad, badURL) = try await make(##"{"appearance": {"highlightColor": "orange; theme = x"}}"##)
        defer { try? FileManager.default.removeItem(at: badURL.deletingLastPathComponent()) }
        #expect(bad.snapshot.highlightColor == nil)
        #expect(bad.snapshot.diagnostics.contains { $0.path == "appearance.highlightColor" })
    }
}
