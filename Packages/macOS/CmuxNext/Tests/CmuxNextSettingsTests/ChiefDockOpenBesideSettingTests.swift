import CmuxNextSettings
import Testing

/// `home.chiefDock.openBeside` (cmux#37365, "i dont want this by default"): a cmux-next.json that never sets it
/// reads off, so a link clicked in the Chief never pins the Chief on screen; docking stays opt-in.
struct ChiefDockOpenBesideSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["chiefDock": .object(["openBeside": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnsetAndTheSettingsRowSaysSo() throws {
        let snapshot = Self.parse(nil)
        #expect(snapshot.chiefDockOpenBeside == false, "an unset openBeside docks the Chief on every link")
        #expect(snapshot.diagnostics.isEmpty)
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.openBesidePath))
        #expect(row.defaultValue == .bool(false), "Settings shows the toggle on for a person who never chose it")
    }

    @Test func turningItOnIsKept() {
        #expect(Self.parse(.bool(true)).chiefDockOpenBeside)
        #expect(!Self.parse(.bool(false)).chiefDockOpenBeside)
    }
}
