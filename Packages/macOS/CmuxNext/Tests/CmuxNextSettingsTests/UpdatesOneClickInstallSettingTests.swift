import CmuxNextSettings
import Testing

/// `updates.oneClickInstall`: off by default (the flow asks before the restart, as before); the
/// person turns it on in Settings > General > Updates. Only the person may: on, one click restarts cmux.
struct UpdatesOneClickInstallSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["updates": .object(["oneClickInstall": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        #expect(!Self.parse(nil).updates.oneClickInstall)
        #expect(!UpdatesSettings.oneClickInstallDefault)
    }

    @Test func thePersonCanTurnItOn() {
        #expect(Self.parse(.bool(true)).updates.oneClickInstall)
        #expect(!Self.parse(.bool(false)).updates.oneClickInstall)
    }

    @Test func settingsListsItAndAgentsMayNotSetIt() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == UpdatesSettings.oneClickInstallPath }, "Settings has no row")
        #expect(row.defaultValue == .bool(false))
        #expect(SettingsSchema.agentRefusedKeys["updates.oneClickInstall"] == .userOnly)
        #expect(SettingsSchema.agentSettable(row) == false)
    }
}
