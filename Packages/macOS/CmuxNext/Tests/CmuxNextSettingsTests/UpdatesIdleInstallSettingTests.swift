import CmuxNextSettings
import Testing

/// `updates.idleInstallMaxWaitSeconds` and `updates.idleInstallQuietSeconds`: a nightly installs a
/// downloaded update by itself after 60 quiet seconds, and never waits more than 10 minutes.
/// Only the person sets them; they show on the Updates: Advanced card.
struct UpdatesIdleInstallSettingTests {
    private static func parse(_ updates: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["updates": .object(updates)]), validDensities: [], validMetrics: [])
    }

    @Test func tenMinutesAndSixtySecondsWhenUnset() {
        let snapshot = Self.parse([:])
        #expect(snapshot.updates.idleInstallMaxWaitSeconds == 600)
        #expect(snapshot.updates.idleInstallQuietSeconds == 60)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func valuesInRangeLoad() {
        let snapshot = Self.parse(["idleInstallMaxWaitSeconds": .number(300), "idleInstallQuietSeconds": .number(30)])
        #expect(snapshot.updates.idleInstallMaxWaitSeconds == 300)
        #expect(snapshot.updates.idleInstallQuietSeconds == 30)
    }

    /// Like every number setting, a value past the range clamps to its edge and says why.
    @Test func anOutOfRangeCapClampsToTheRangeAndSaysWhy() {
        let snapshot = Self.parse(["idleInstallMaxWaitSeconds": .number(86_400)])
        #expect(snapshot.updates.idleInstallMaxWaitSeconds == UpdatesSettings.idleInstallMaxWaitRange.upperBound)
        #expect(snapshot.diagnostics.contains { $0.path == "updates.idleInstallMaxWaitSeconds" })
    }

    @Test(arguments: ["updates.idleInstallMaxWaitSeconds", "updates.idleInstallQuietSeconds"])
    func agentsMayNotSetIt(key: String) {
        #expect(SettingsSchema.agentRefusedKeys[key] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains(key))
    }

    @Test func bothRowsShowOnTheUpdatesAdvancedCard() throws {
        let updates = try #require(SettingsPageLayout().categories().first { $0.spec.id == "updates" })
        let card = try #require(updates.groups.first { $0.rows.contains("updates.idleInstallMaxWaitSeconds") })
        #expect(card.rows == ["updates.idleInstallMaxWaitSeconds", "updates.idleInstallQuietSeconds"])
        #expect(card.title.key == "settings.pageGroup.updatesAdvanced")
    }
}
