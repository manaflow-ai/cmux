import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.style` (plans/cmux-next/minimal-sidebar.md): the standard sidebar by default; "rail"
/// opts into the thin rail; a bad value keeps the default and says why.
struct SidebarStyleSettingTests {
    private func snapshot(_ style: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = style.map { .object(["sidebar": .object(["style": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsTheStandardSidebar() {
        #expect(snapshot(nil).sidebarSections.style == .standard)
    }

    @Test func railIsRead() {
        #expect(snapshot("rail").sidebarSections.style == .rail)
    }

    @Test func aBadValueKeepsStandardWithADiagnostic() {
        let parsed = snapshot("hairline")
        #expect(parsed.sidebarSections.style == .standard)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.style" })
    }

    @Test func theSettingsWindowListsItWithTheDocumentedDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: SidebarSectionsSetting.stylePath))
        #expect(row.defaultValue == .string("standard"))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.style"))
    }
}
