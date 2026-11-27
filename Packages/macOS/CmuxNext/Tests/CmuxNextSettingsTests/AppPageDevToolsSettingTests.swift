import CmuxNextSettings
import Testing

/// `developerTools.appPages`: Settings > Advanced turns developer tools for cmux's own pages (the
/// agent chat, Home, Markdown, Settings) on and off. On by default in every build.
struct AppPageDevToolsSettingTests {
    @Test func theRowIsInAdvancedAndOnByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["developerTools", "appPages"]))
        #expect(descriptor.section == .advanced)
        #expect(descriptor.kind == .toggle)
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.isShownOnSettingsPage)
    }
}
