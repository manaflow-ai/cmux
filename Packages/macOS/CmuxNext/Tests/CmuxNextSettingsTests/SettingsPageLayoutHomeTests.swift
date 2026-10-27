import CmuxNextSettings
import Testing

/// Every row the Settings page shows has exactly one home in `SettingsPageLayout`.
/// A schema group the layout never places drops its rows from the page without
/// an error: the Motion switches (`settings.group.motion`) had no row until the
/// web check `categories.test.ts` caught it after the schema export, a Mac
/// regeneration later. This catches it where the schema changes.
struct SettingsPageLayoutHomeTests {
    @Test func everyShownRowHasExactlyOneHome() {
        let placed = SettingsPageLayout().categories().flatMap { $0.groups.flatMap(\.rows) }
        var counts: [String: Int] = [:]
        for row in placed { counts[row, default: 0] += 1 }
        let shown = SettingsSchema.all.filter(\.isShownOnSettingsPage).map(\.id)
        let homeless = shown.filter { counts[$0] == nil }.sorted()
        let doubled = counts.filter { $0.value > 1 }.map(\.key).sorted()
        #expect(homeless == [], "rows the Settings page shows with no group in SettingsPageLayout")
        #expect(doubled == [], "rows with more than one home")
    }
}
