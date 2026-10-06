import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Leo (2026-10-06): a section header's menu hides Projects or Recents, and
/// Settings brings it back: `sidebar.showProjects` and `sidebar.showRecents`.
@Suite struct SidebarHiddenSectionsSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func projectsAndRecentsShowByDefault() throws {
        let sections = try parse("{}").sidebarSections
        #expect(sections.showProjects && sections.showRecents)
    }

    @Test func eitherOneHides() throws {
        let sections = try parse(#"{"sidebar": {"showProjects": false, "showRecents": false}}"#).sidebarSections
        #expect(!sections.showProjects && !sections.showRecents)
    }

    @Test func aBadValueKeepsTheSectionShown() throws {
        let snapshot = try parse(#"{"sidebar": {"showRecents": "no"}}"#)
        #expect(snapshot.sidebarSections == .defaults)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.showRecents"])
    }

    @Test func settingsListsBothAsToggles() {
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showProjects"])?.kind == .toggle)
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showRecents"])?.kind == .toggle)
    }
}
