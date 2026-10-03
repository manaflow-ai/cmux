import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The user's theme pick (`appearance.theme`, plus anything a newer build
/// adds next to it) survives every cmux.json write that was not asked to
/// change it: a settings write, Reset All, a migration, and writes racing
/// the file watcher's reload. Writes edit one key of the JSONC source in
/// place (`CmuxConfigFile.set`), never re-encode a decoded model.
@MainActor
@Suite struct ThemePersistenceTests {
    /// A file as a user (or a newer cmux) left it: a theme, font, keys this
    /// build does not know, and comments.
    static let userFile = """
        {
          // my look
          "appearance": {
            "theme": "Catppuccin Mocha",
            "density": "comfortable",
            "futureKey": { "glass": true }
          },
          "terminal": { "fontFamily": "Berkeley Mono" },
          "future": { "backgroundOpacity": 0.85, "backgroundBlur": 20 },
          "app": { "quitBehavior": "end" }
        }
        """

    func make(_ text: String = userFile) throws -> (SettingsController, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-theme-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        return (settings, url, directory)
    }

    func document(_ url: URL) throws -> JSONValue { try JSONC.parse(String(contentsOf: url, encoding: .utf8)) }

    /// The pick and the keys this build does not know are all still there.
    func expectUserLookKept(_ url: URL, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let root = try document(url)
        #expect(root.value(at: ["appearance", "theme"]) == "Catppuccin Mocha", comment, sourceLocation: sourceLocation)
        #expect(root.value(at: ["appearance", "futureKey", "glass"]) == true, comment, sourceLocation: sourceLocation)
        #expect(root.value(at: ["terminal", "fontFamily"]) == "Berkeley Mono", comment, sourceLocation: sourceLocation)
        #expect(root.value(at: ["future", "backgroundOpacity"]) == 0.85, comment, sourceLocation: sourceLocation)
        #expect(root.value(at: ["future", "backgroundBlur"]) == 20, comment, sourceLocation: sourceLocation)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("// my look"), comment, sourceLocation: sourceLocation)
    }

    @Test func unrelatedWritesKeepTheThemeAndUnknownKeys() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let density = try #require(SettingsSchema.descriptor(for: ["appearance", "density"]))
        let padding = try #require(SettingsSchema.descriptor(for: ["layout", "panePadding"]))

        try await settings.setDensity(.compact)
        try expectUserLookKept(url, "density write")
        try await settings.setSetting(density, to: nil)
        try expectUserLookKept(url, "density reset (removes its key)")
        try await settings.setSetting(padding, to: 8)
        try await settings.setSetting(padding, to: nil)
        try expectUserLookKept(url, "pane padding set and reset")
        try await settings.setAnimationSpeed(.off)
        try await settings.setShortcut(Shortcut("g", modifiers: [.command, .shift]), for: "tabGroup.create")
        try expectUserLookKept(url, "animation speed and shortcut")
        try await settings.file.apply([(["ui", "animationSpeed"], nil), (["browser", "showBookmarksBar"], true)])
        try expectUserLookKept(url, "several edits in one publish")
        // Reset All removes what the schema owns, except the look picked at
        // onboarding (`SettingsSchema.keptOnResetAll`): the theme and font stay.
        try await settings.resetAllSettings()
        try expectUserLookKept(url, "Reset All Settings")
        #expect(try document(url).value(at: ["appearance", "density"]) == nil)
    }

    @Test func theQuitBehaviorMigrationKeepsTheTheme() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await settings.migrateLegacyQuitBehavior())
        #expect(try document(url).value(at: ["app", "quitBehavior"]) == "end-keep-layout")
        try expectUserLookKept(url, "legacy quit behavior migration")
        // A second launch has nothing to migrate and writes nothing.
        let before = try String(contentsOf: url, encoding: .utf8)
        #expect(try await settings.migrateLegacyQuitBehavior() == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }

    /// A theme this build does not ship (a newer Ghostty's, a user's own
    /// file) loads as written: no reset, no rewrite, no diagnostic.
    @Test func anUnknownThemeLoadsAsWritten() async throws {
        let text = Self.userFile.replacingOccurrences(of: "Catppuccin Mocha", with: "Theme From A Newer Ghostty")
        let (settings, url, directory) = try make(text)
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        #expect(settings.snapshot.root.value(at: ["appearance", "theme"]) == "Theme From A Newer Ghostty")
        #expect(!settings.diagnostics.contains { $0.path.hasPrefix("appearance") })
        #expect(try String(contentsOf: url, encoding: .utf8) == text, "loading never writes")
        try await settings.setDensity(.compact)
        #expect(try document(url).value(at: ["appearance", "theme"]) == "Theme From A Newer Ghostty")
    }

    /// Writes of different keys landing while the watcher reloads: each
    /// write reads the file it edits inside the actor, so none publishes a
    /// stale copy over another's key or the theme.
    @Test func writesRacingTheWatcherKeepEveryKey() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.start()
        defer { settings.stop() }
        await settings.reload()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { try await settings.set(.number(Double(index)), at: ["future", "race\(index)"]) }
            }
            group.addTask { try await settings.setDensity(.compact) }
            group.addTask { try await settings.setAnimationSpeed(.off) }
            group.addTask { await settings.reload() }
            try await group.waitForAll()
        }
        try expectUserLookKept(url, "concurrent writes")
        let root = try document(url)
        for index in 0..<8 { #expect(root.value(at: ["future", "race\(index)"]) == .number(Double(index))) }
        #expect(root.value(at: ["appearance", "density"]) == "compact")
        await settings.reload()
        #expect(settings.snapshot.root.value(at: ["appearance", "theme"]) == "Catppuccin Mocha")
    }
}
