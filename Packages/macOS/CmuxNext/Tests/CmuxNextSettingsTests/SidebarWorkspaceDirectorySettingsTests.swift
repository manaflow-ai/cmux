import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Lawrence (2026-10-06): workspace rows show their directory only when
/// `sidebar.showWorkspaceDirectory` is on.
@Suite struct SidebarWorkspaceDirectorySettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() throws {
        #expect(try !parse("{}").sidebarSections.showWorkspaceDirectory)
    }

    @Test func turnsOn() throws {
        #expect(try parse(#"{"sidebar": {"showWorkspaceDirectory": true}}"#).sidebarSections.showWorkspaceDirectory)
    }

    @Test func settingsListsItAsAToggle() {
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showWorkspaceDirectory"])?.kind == .toggle)
    }
}
