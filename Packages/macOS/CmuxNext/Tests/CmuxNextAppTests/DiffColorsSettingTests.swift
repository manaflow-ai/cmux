import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDiff
import CmuxNextDesign
import CmuxNextWakeups
@testable import CmuxNextSettings
import Foundation
import Testing

/// Diff Colors (cx-wqn5): the diff page's add/remove colors follow the theme unless a person picks
/// Muted or Standard in Settings; `cmux.diff.prefs` carries the choice to the page.
struct DiffColorsSettingTests {
    @Test func settingsOfferThemeMutedAndStandardWithThemeByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["diff", "colors"]))
        #expect(row.defaultValue == .string("theme"))
        for value in ["theme", "muted", "standard"] {
            #expect(row.accepts(.string(value)))
        }
        #expect(!row.accepts(.string("neon")))
    }

    @Test func diffPrefsCarryTheChoiceToThePage() {
        #expect(DiffPrefKey.accepts("colors", .string("muted")))
        #expect(!DiffPrefKey.accepts("colors", .string("neon")))
        let prefs = DiffPrefKey.sanitized(.object(["colors": .string("standard"), "layout": .string("split")]))
        #expect(prefs["colors"] == .string("standard"))
    }

    /// A change in Settings reaches every agent page (the Changes view's colors) and every open diff
    /// tab (the `cmux.diff.prefs` stream) at once, without a reload.
    @MainActor @Test func aChangeReachesTheAgentPagesAndTheOpenDiffTabs() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-diff-colors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"diff":{"colors":"muted"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        let pages = AgentPanePageSettings()
        pages.follow(settings) {}
        let prefs = SettingsDiffPrefs(mainWork: MainWorkScheduler(budget: MainFrameBudget())) { settings }
        var streamed: [JSONValue] = []
        let stop = prefs.listen { streamed.append($0["colors"] ?? .null) }
        defer { stop() }
        for _ in 0..<200 where pages.diffColors != "muted" { await Task.yield() }
        #expect(pages.diffColors == "muted")

        #expect(streamed.isEmpty, "the stream pushed the prefs the tab opened with")

        try await settings.set(.string("standard"), at: ["diff", "colors"])
        // The stream's push is one task on the scheduler: give the main run loop turns, not only yields.
        for _ in 0..<200 where pages.diffColors != "standard" || streamed.last != .string("standard") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pages.diffColors == "standard")
        #expect(streamed.last == .string("standard"))
    }
}
