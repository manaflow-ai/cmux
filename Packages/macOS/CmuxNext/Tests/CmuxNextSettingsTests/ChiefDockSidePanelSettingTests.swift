import CmuxNextSettings
import Testing

/// `home.chiefDock.sidePanel` (Chief in Side Panel): a cmux-next.json that never sets it reads off, so nothing docks
/// the Chief by default (cmux#37365); turned on, every window keeps the Chief docked as a side panel.
struct ChiefDockSidePanelSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["chiefDock": .object(["sidePanel": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnsetAndTheSettingsRowSaysSo() throws {
        let snapshot = Self.parse(nil)
        #expect(snapshot.chiefDockSidePanel == false, "an unset sidePanel docks the Chief")
        #expect(snapshot.diagnostics.isEmpty)
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.sidePanelPath), "Settings has no Chief in Side Panel row")
        #expect(row.defaultValue == .bool(false), "Settings shows the toggle on for a person who never chose it")
    }

    @Test func turningItOnIsKept() {
        #expect(Self.parse(.bool(true)).chiefDockSidePanel)
        #expect(!Self.parse(.bool(false)).chiefDockSidePanel)
        #expect(!Self.parse(.string("yes")).chiefDockSidePanel, "a value that is not a bool turned it on")
        #expect(!Self.parse(.string("yes")).diagnostics.isEmpty, "a value that is not a bool says nothing")
    }
}
