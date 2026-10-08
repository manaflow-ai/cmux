import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Settings text goes through the non-trapping module bundle lookup.
struct SettingsTextTests {
    /// Fleet SwiftPM copies source catalogs without compiling `.lproj` tables; CI covers those.
    nonisolated private static func stringCatalogsCompiled() -> Bool {
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            || Bundle.module.path(forResource: "en", ofType: "lproj") != nil
    }

    @Test func settingsStringTableIsFound() {
        #expect(ModuleResourceBundle.settings.bundle != nil)
    }

    @Test func missingStringTableFallsBackToEnglish() {
        let missing = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: [])
        #expect(SettingsText.text("settings.group.engine", "Engine", strings: missing) == "Engine")
    }

    /// The lookup reads the real table: German comes back, not the English default.
    @Test(.enabled(if: stringCatalogsCompiled()))
    func germanTableIsRead() {
        let german = ModuleResourceBundle.settings.localization("de")
        #expect(german.bundle != nil)
        #expect(SettingsText.text("settings.group.memory", "Memory", strings: german) == "Speicher")
    }
}
