import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.reorderHaptics` (https://github.com/manaflow-ai/cmux/issues/48598): on by default, false turns the
/// sidebar's reorder taps off, a bad value keeps them on and says why, and every settings surface lists it.
struct SidebarReorderHapticsSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["reorderHaptics": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsOn() {
        #expect(snapshot(nil).sidebarSections.reorderHaptics)
    }

    @Test func falseTurnsItOff() {
        #expect(!snapshot(.bool(false)).sidebarSections.reorderHaptics)
    }

    @Test func aBadValueKeepsItOnWithADiagnostic() {
        let parsed = snapshot("loud")
        #expect(parsed.sidebarSections.reorderHaptics)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.reorderHaptics" })
    }

    @Test func theSchemaListsItForThePaletteCLIAndAgents() throws {
        let row = try #require(SettingsSchema.descriptor(for: SidebarSectionsSetting.reorderHapticsPath))
        #expect(row.defaultValue == .bool(true))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.reorderHaptics"))
    }
}
