@testable import CmuxNextApp
import CmuxNextSettings
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
}
