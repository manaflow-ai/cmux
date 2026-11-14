import CmuxNextSettings
import Testing

/// `home.chiefDock.openBeside`: a cmux-next.json that never sets it reads on, so a link clicked in the Chief opens its
/// workspace with the Chief floating over it (user 2026-11-06). That panel never docks and never comes back after a
/// relaunch, so the Chief is still never pinned on screen unless the person docks it (cmux#37365).
struct ChiefDockOpenBesideSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["chiefDock": .object(["openBeside": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onWhenUnsetAndTheSettingsRowSaysSo() throws {
        let snapshot = Self.parse(nil)
        #expect(snapshot.chiefDockOpenBeside == true, "an unset openBeside opens no Chief over a link's workspace")
        #expect(snapshot.diagnostics.isEmpty)
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.openBesidePath))
        #expect(row.defaultValue == .bool(true), "Settings shows the toggle off for a person who never chose it")
    }

    @Test func turningItOnIsKept() {
        #expect(Self.parse(.bool(true)).chiefDockOpenBeside)
        #expect(!Self.parse(.bool(false)).chiefDockOpenBeside)
    }
}
