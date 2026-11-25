import CmuxNextSettings
import Testing

/// `updates.installWhenIdle` and `updates.installWhenIdleMinutes` (Leo 2026-11-19: "like update when
/// idle"): an opt-in, off by default, that installs a downloaded update once cmux has been idle 15
/// minutes. Only the person sets them; they show on the Updates card right after Install Updates When
/// Quitting.
struct UpdatesInstallWhenIdleSettingTests {
    private static func parse(_ updates: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["updates": .object(updates)]), validDensities: [], validMetrics: [])
    }

    @Test func offAndFifteenMinutesWhenUnset() {
        let snapshot = Self.parse([:])
        #expect(snapshot.updates.installWhenIdle == false)
        #expect(snapshot.updates.installWhenIdleMinutes == 15)
        #expect(UpdatesSettings.installWhenIdleMinutesRange == 1...240)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func valuesInRangeLoad() {
        let snapshot = Self.parse(["installWhenIdle": .bool(true), "installWhenIdleMinutes": .number(30)])
        #expect(snapshot.updates.installWhenIdle)
        #expect(snapshot.updates.installWhenIdleMinutes == 30)
        #expect(snapshot.diagnostics.isEmpty)
    }

    /// Like every number setting, a value past the range clamps to its edge and says why.
    @Test(arguments: [(0.0, 1.0), (10_000.0, 240.0)])
    func anOutOfRangeTimeClampsToTheRangeAndSaysWhy(value: Double, clamped: Double) {
        let snapshot = Self.parse(["installWhenIdleMinutes": .number(value)])
        #expect(snapshot.updates.installWhenIdleMinutes == clamped)
        #expect(snapshot.diagnostics.contains { $0.path == "updates.installWhenIdleMinutes" })
    }

    @Test(arguments: ["updates.installWhenIdle", "updates.installWhenIdleMinutes"])
    func agentsMayNotSetIt(key: String) {
        #expect(SettingsSchema.agentRefusedKeys[key] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains(key))
    }

    @Test func bothRowsFollowInstallOnQuitOnTheUpdatesCard() throws {
        let updates = try #require(SettingsPageLayout().categories().first { $0.spec.id == "updates" })
        let card = try #require(updates.groups.first { $0.rows.contains("updates.installWhenIdle") })
        #expect(card.title.key == "settings.group.updates")
        let quit = try #require(card.rows.firstIndex(of: "updates.installOnQuit"))
        #expect(Array(card.rows[quit...].prefix(3)) == [
            "updates.installOnQuit", "updates.installWhenIdle", "updates.installWhenIdleMinutes",
        ])
    }
}
