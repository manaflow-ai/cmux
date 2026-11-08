import Foundation
import Testing
@testable import CmuxSettings

@Suite("WorkspaceAutoReorderMode")
struct WorkspaceAutoReorderModeTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "cmux-auto-reorder-mode-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func legacyBooleansDecodeAsTheirModes() {
        #expect(WorkspaceAutoReorderMode.decodeFromUserDefaults(true) == .notifications)
        #expect(WorkspaceAutoReorderMode.decodeFromUserDefaults(false) == .off)
        #expect(WorkspaceAutoReorderMode.decodeFromJSON(NSNumber(value: true)) == .notifications)
        #expect(WorkspaceAutoReorderMode.decodeFromJSON(NSNumber(value: false)) == .off)
    }

    @Test func stringsDecodeByRawValue() {
        for mode in WorkspaceAutoReorderMode.allCases {
            #expect(WorkspaceAutoReorderMode.decodeFromUserDefaults(mode.rawValue) == mode)
            #expect(WorkspaceAutoReorderMode.decodeFromJSON(mode.rawValue) == mode)
        }
        #expect(WorkspaceAutoReorderMode.decodeFromUserDefaults("sometimes") == nil)
        #expect(WorkspaceAutoReorderMode.decodeFromJSON(NSNumber(value: 1)) == nil)
    }

    @Test func legacyModesKeepTheirBooleanRepresentation() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let key = SettingCatalog().app.reorderOnNotification

        client.set(.notifications, for: key)
        #expect(defaults.object(forKey: key.userDefaultsKey) as? Bool == true)
        client.set(.off, for: key)
        #expect(defaults.object(forKey: key.userDefaultsKey) as? Bool == false)
        client.set(.agentActivity, for: key)
        #expect(defaults.string(forKey: key.userDefaultsKey) == "agentActivity")
        #expect(client.value(for: key) == .agentActivity)

        #expect(WorkspaceAutoReorderMode.notifications.encodeForJSON() as? Bool == true)
        #expect(WorkspaceAutoReorderMode.off.encodeForJSON() as? Bool == false)
        #expect(WorkspaceAutoReorderMode.agentActivity.encodeForJSON() as? String == "agentActivity")
    }

    @Test func defaultStaysNotifications() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        #expect(client.value(for: SettingCatalog().app.reorderOnNotification) == .notifications)
    }
}
