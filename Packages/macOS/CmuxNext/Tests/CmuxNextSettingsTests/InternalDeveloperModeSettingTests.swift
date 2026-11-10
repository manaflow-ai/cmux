@testable import CmuxNextSettings
import Testing

/// `app.internalDeveloperMode` (cmux-ad i11): off by default, in Settings > Development, and listed by the
/// Command Palette only in a build with developer tools (DEV, NIGHTLY), never in Release or RC.
@Suite struct InternalDeveloperModeSettingTests {
    private static var row: SettingDescriptor? {
        SettingsSchema.all.first { $0.path == InternalDeveloperModeSetting.configPath }
    }

    @Test func itIsAnOffToggleInDevelopment() throws {
        let row = try #require(Self.row)
        #expect(row.section == .development)
        #expect(row.kind == .toggle)
        #expect(!InternalDeveloperModeSetting().value(in: .object([:])))
        #expect(InternalDeveloperModeSetting().value(in: .object(["app": .object(["internalDeveloperMode": .bool(true)])])))
    }

    @Test func thePaletteListsDevelopmentRowsOnlyWithDeveloperTools() throws {
        let row = try #require(Self.row)
        #expect(row.isPaletteListed(developerTools: true))
        #expect(!row.isPaletteListed(developerTools: false))
        let release = SettingsSchema.all.filter { $0.isPaletteListed(developerTools: false) }
        #expect(!release.isEmpty)
        #expect(release.allSatisfy { $0.section != .development })
    }
}
