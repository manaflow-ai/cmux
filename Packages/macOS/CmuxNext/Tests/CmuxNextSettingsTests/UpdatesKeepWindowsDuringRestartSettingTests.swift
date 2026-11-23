import CmuxNextSettings
import Testing

/// `updates.keepWindowsDuringRestart` (Leo 2026-11-23: "restart to update, just do the normal close to
/// update again ... the layout shift and the jarringness is a bit too much. for now..."): off by default,
/// so a relaunch closes the windows and the new process opens them again; on, the relaunch afterimage
/// keeps a picture of each window on screen.
struct UpdatesKeepWindowsDuringRestartSettingTests {
    private static let key = "updates.keepWindowsDuringRestart"

    private static func parse(_ updates: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["updates": .object(updates)]), validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnset() {
        let snapshot = Self.parse([:])
        #expect(snapshot.updates.keepWindowsDuringRestart == false)
        #expect(UpdatesSettings.keepWindowsDuringRestartDefault == false)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func onLoads() {
        let snapshot = Self.parse(["keepWindowsDuringRestart": .bool(true)])
        #expect(snapshot.updates.keepWindowsDuringRestart)
        #expect(snapshot.diagnostics.isEmpty)
    }

    /// How a restart looks is a display choice: an agent may set it back and forth.
    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains(Self.key))
        #expect(SettingsSchema.agentRefusedKeys[Self.key] == nil)
    }

    @Test func theRowIsOnTheUpdatesCard() throws {
        let updates = try #require(SettingsPageLayout().categories().first { $0.spec.id == "updates" })
        let card = try #require(updates.groups.first { $0.rows.contains(Self.key) })
        #expect(card.title.key == "settings.group.updates")
    }
}
