import CmuxNextSettings
import Testing

/// `sidebar.cloudGroup`: on by default, so a new Cloud workspace joins the
/// sidebar's Cloud group; false turns that off. The Settings row and the
/// value the app reads agree.
struct CloudGroupSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["cloudGroup": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.cloudGroup)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func falseTurnsItOff() {
        #expect(!Self.parse(.bool(false)).sidebarSections.cloudGroup)
        #expect(Self.parse(.bool(true)).sidebarSections.cloudGroup)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("no"))
        #expect(snapshot.sidebarSections.cloudGroup)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.cloudGroup" })
    }

    @Test func theSettingsRowIsOnByDefaultAndAgentsMayChangeIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", "cloudGroup"]))
        #expect(row.defaultValue == .bool(true))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.cloudGroup"))
    }
}
