import CmuxNextSettings
import Testing

/// "minimap" names the editor and transcript minimaps in palette search, not the column scroll bar:
/// the Settings palette rows (SettingsPaletteProvider) search these keywords as the action catalog's do.
struct StripScrollbarKeywordTests {
    @Test func theColumnScrollBarSettingIsNotFoundAsMinimap() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: StripScrollbarSetting.configPath))
        #expect(!descriptor.keywords.contains("minimap"))
        #expect(descriptor.keywords.contains("scrollbar"))
        #expect(descriptor.keywords.contains("visible range"))
    }
}
