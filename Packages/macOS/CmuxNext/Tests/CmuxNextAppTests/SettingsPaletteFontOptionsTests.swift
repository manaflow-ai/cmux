@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A font family setting's palette values (`SettingsPaletteSource.fontOptions`): the default first,
/// a current family that is not installed kept, the fonts picked lately next, then every other
/// installed family, each once.
@MainActor
struct SettingsPaletteFontOptionsTests {
    @Test func recentFontsLeadAndEachFamilyShowsOnce() {
        let options = SettingsPaletteSource.fontOptions(current: "Menlo", families: ["Iosevka", "Menlo", "SF Mono"],
                                                        recent: ["Fira Code", "SF Mono", "Menlo"], defaultLabel: "Ghostty Config")
        #expect(options.map(\.title) == ["Ghostty Config", "SF Mono", "Menlo", "Iosevka"])
        #expect(options.map(\.isCurrent) == [false, false, true, false])
        #expect(options.first?.value == nil)
    }

    @Test func aCurrentFamilyNotInstalledStaysListedAsCurrent() {
        let options = SettingsPaletteSource.fontOptions(current: "Gone Mono", families: ["Menlo"], recent: [], defaultLabel: "Default")
        #expect(options.map(\.title) == ["Default", "Gone Mono", "Menlo"])
        #expect(options[1].isCurrent)
    }
}
