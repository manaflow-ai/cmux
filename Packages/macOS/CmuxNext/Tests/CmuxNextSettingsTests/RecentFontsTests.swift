import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Fonts written lately (`RecentFonts`): Settings' font lists and the palette's Change Font… lead
/// with them, so switching back and forth is one step. Every font family write records its family,
/// newest first, each once, at most `RecentFonts.limit`; other writes record nothing.
@MainActor @Suite(.serialized) struct RecentFontsTests {
    static func defaults() -> (UserDefaults, String) {
        let suite = "cn-recent-fonts-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func aPickMovesTheFamilyToTheFrontOnceAndTheListKeepsItsLimit() {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentFonts(defaults: defaults)
        for family in ["A", "B", "C", "D", "E", "F", "G"] { recent.record(family) }
        #expect(recent.families == ["G", "F", "E", "D", "C", "B"])
        recent.record(" D ")
        #expect(recent.families == ["D", "G", "F", "E", "C", "B"])
        recent.record("  ")
        #expect(recent.families.count == RecentFonts.limit)
    }

    @Test func everyFontFamilyWriteRecordsItsFamilyAndOtherWritesNothing() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-recent-fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.recentFonts = RecentFonts(defaults: defaults)
        await settings.reload()

        try await settings.setSetting(at: ["terminal", "fontFamily"], to: .string("Menlo"), by: .user)
        try await settings.setSetting(at: ["markdown", "code", "family"], to: .string("SF Mono"), by: .user)
        try await settings.setSetting(at: ["terminal", "fontSize"], to: .number(15), by: .user)
        try await settings.setSetting(at: ["terminal", "fontFamily"], to: nil, by: .user)
        #expect(settings.recentFonts.families == ["SF Mono", "Menlo"])
    }
}
