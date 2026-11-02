@testable import CmuxNextSettings
import Testing

/// Settings > Devices holds Mac Screen's sharing switch, device permissions and relays. NIGHTLY
/// and Release reach the built-in production hub (`DeviceHubSettings.resolvedBaseURL`), so the
/// category shows in every build; only Development (the hub address override and the Mac Screen
/// debug switches) stays DEV-only.
struct DevicesCategoryLayoutTests {
    private static let categories = SettingsPageLayout().categories()

    @Test func devicesShowsInEveryBuild() throws {
        let devices = try #require(Self.categories.first { $0.spec.id == "devices" })
        #expect(!devices.spec.devOnly, "a release build's Settings must list Devices")
        #expect(devices.spec.lead == [.devices])
    }

    @Test func onlyDevelopmentIsDevOnly() {
        #expect(Self.categories.filter(\.spec.devOnly).map(\.spec.id) == ["development"])
    }

    @Test func theExportMarksOnlyDevelopmentDevOnly() throws {
        let page = SettingsSchemaExport().page { text, key in ["text": text, "key": key as Any] }
        let categories = try #require(page["categories"] as? [[String: Any]])
        let devOnly = categories.filter { $0["dev_only"] as? Bool == true }.compactMap { $0["id"] as? String }
        #expect(devOnly == ["development"])
        #expect(categories.contains { $0["id"] as? String == "devices" })
    }
}
