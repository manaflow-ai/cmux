import CmuxNextSettings
import Testing

/// Install When Idle, the `idle` choice of `updates.automatic` (Leo 2026-11-19: "like update when idle"), and
/// `updates.installWhenIdleMinutes`: an opt-in that installs a downloaded update once cmux has been idle 15
/// minutes. Only the person sets them. The minutes live in cmux-next.json only (Leo 2026-11-22: "maybe too
/// many settings and bullshit that can be consolidated").
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
        let snapshot = Self.parse(["automatic": .string("idle"), "installWhenIdleMinutes": .number(30)])
        #expect(snapshot.updates.installWhenIdle)
        #expect(snapshot.updates.downloadAutomatically, "an idle install needs the update downloaded")
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

    /// The retired toggle still turns it on while `updates.automatic` is unset.
    @Test func theOldToggleStillTurnsItOn() {
        #expect(Self.parse(["installWhenIdle": .bool(true)]).updates.automatic == .idle)
        #expect(Self.parse(["installWhenIdle": .bool(true), "automatic": .string("notify")]).updates.installWhenIdle == false)
    }

    @Test(arguments: ["updates.automatic", "updates.installWhenIdleMinutes"])
    func agentsMayNotSetIt(key: String) {
        #expect(SettingsSchema.agentRefusedKeys[key] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains(key))
    }

    @Test func automaticUpdatesIsOnTheUpdatesCard() throws {
        let updates = try #require(SettingsPageLayout().categories().first { $0.spec.id == "updates" })
        let card = try #require(updates.groups.first { $0.rows.contains("updates.automatic") })
        #expect(card.title.key == "settings.group.updates")
        #expect(!updates.groups.contains { $0.rows.contains("updates.installWhenIdle") })
    }
}
