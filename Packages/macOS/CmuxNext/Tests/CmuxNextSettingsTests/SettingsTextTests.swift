import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// Settings text goes through the non-trapping module bundle lookup.
struct SettingsTextTests {
    @Test func settingsStringTableIsFound() {
        #expect(ModuleResourceBundle.settings.bundle != nil)
    }

    @Test func missingStringTableFallsBackToEnglish() {
        let missing = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: [])
        #expect(SettingsText.text("settings.group.engine", "Engine", strings: missing) == "Engine")
    }
}
