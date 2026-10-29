@testable import CmuxNextSettings
import Testing

/// `debug.mainJobGate` (``MainJobGateSettings``): on by default, a non-boolean falls
/// back, and the row is in the schema, off the page while the `mainJobGate` feature is off, and not
/// settable by agents (a debug switch).
struct MainJobGateSettingsTests {
    @Test func defaultIsOn() {
        #expect(MainJobGateSettings(.object([:])).enabled)
    }

    @Test func valueReadAndInvalidFallsBack() {
        #expect(!MainJobGateSettings(.object(["debug": .object(["mainJobGate": .bool(false)])])).enabled)
        #expect(MainJobGateSettings(.object(["debug": .object(["mainJobGate": .string("no")])])).enabled)
    }

    @Test func theSchemaRowMatchesTheDefault() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "debug.mainJobGate" })
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(MainJobGateSettings.enabledDefault))
        #expect(!row.isShownOnSettingsPage, "behind the mainJobGate feature")
        #expect(!SettingsSchema.agentSettableKeys.contains(row.id))
    }
}
