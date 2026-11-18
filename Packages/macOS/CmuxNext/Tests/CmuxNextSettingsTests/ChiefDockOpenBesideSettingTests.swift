import CmuxNextSettings
import Testing

/// `home.chiefDock.openBeside`: a cmux-next.json that never sets it reads off, so a link clicked in the Chief opens only
/// its target, with no floating Chief over it (cmux#45889: "links should just open their target"). Turned on, a link
/// opens its workspace with the Chief floating over it (user 2026-11-06).
struct ChiefDockOpenBesideSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["chiefDock": .object(["openBeside": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnsetAndTheSettingsRowSaysSo() throws {
        let snapshot = Self.parse(nil)
        #expect(snapshot.chiefDockOpenBeside == false, "an unset openBeside floats the Chief over a link's workspace")
        #expect(snapshot.diagnostics.isEmpty)
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.openBesidePath))
        #expect(row.defaultValue == .bool(false), "Settings shows the toggle on for a person who never chose it")
    }

    @Test func turningItOnIsKept() {
        #expect(Self.parse(.bool(true)).chiefDockOpenBeside)
        #expect(!Self.parse(.bool(false)).chiefDockOpenBeside)
    }
}
