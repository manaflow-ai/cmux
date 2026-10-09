import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Leo (2026-10-06): a section header's menu hides Projects, and Settings
/// brings it back (`sidebar.showProjects`). The section under the workspaces
/// is the optional Chats section, which keeps its one setting
/// (`sidebar.showChats`, SIDEBAR-NO-RECENTS); there is no Show Recents.
@Suite struct SidebarHiddenSectionsSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func projectsShowByDefault() throws {
        let sections = try parse("{}").sidebarSections
        #expect(sections.showProjects && !sections.showChats)
    }

    @Test func projectsHide() throws {
        #expect(!(try parse(#"{"sidebar": {"showProjects": false}}"#).sidebarSections.showProjects))
    }

    @Test func aBadValueKeepsTheSectionShown() throws {
        let snapshot = try parse(#"{"sidebar": {"showProjects": "no"}}"#)
        #expect(snapshot.sidebarSections == .defaults)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.showProjects"])
    }

    @Test func settingsListsProjectsAndNoRecents() {
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showProjects"])?.kind == .toggle)
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showRecents"]) == nil, "Chats has Show Chats")
    }
}
