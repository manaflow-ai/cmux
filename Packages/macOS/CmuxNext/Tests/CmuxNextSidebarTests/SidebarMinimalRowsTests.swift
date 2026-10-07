import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Lawrence (2026-10-06): workspace rows are minimal by default. The passive
/// directory line shows only with `sidebar.showWorkspaceDirectory`; a live
/// status always earns the second line.
@MainActor @Suite struct SidebarMinimalRowsTests {
    private let local = SidebarMachine(id: .local, name: "Local", kind: .local)

    private func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(local), nodes: [
            .workspace(SidebarWorkspace(id: id("a"), title: "a", subtitle: "~/src/app")),
            .workspace(SidebarWorkspace(id: id("b"), title: "b", subtitle: "~", status: "Running tests")),
        ])]
    }

    private func rows(showsDirectory: Bool) -> [SidebarRow] {
        var options = SidebarLayoutOptions()
        options.showsWorkspaceDirectory = showsDirectory
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: options).rows
    }

    @Test func theDirectoryLineHidesUnlessShown() {
        let m = SidebarLayoutMetrics.standard
        let minimal = rows(showsDirectory: false)
        #expect(minimal[0].height == m.rowHeight && minimal[0].hidesDirectory)
        #expect(minimal[1].height == m.rowHeightWithSubtitle)
        let full = rows(showsDirectory: true)
        #expect(full[0].height == m.rowHeightWithSubtitle && !full[0].hidesDirectory)
    }

    @Test func theRowShowsOnlyALiveStatus() {
        let ws = SidebarWorkspace(id: id("a"), title: "a", subtitle: "~/src/app")
        #expect(ws.detail(showsDirectory: false) == nil)
        #expect(ws.detail(showsDirectory: true) == "~/src/app")
        let live = SidebarWorkspace(id: id("b"), title: "b", subtitle: "~", status: "Running tests")
        #expect(live.detail(showsDirectory: false) == "Running tests")
    }

    @Test func theSidebarIsMinimalUntilTheSettingIsOn() {
        let model = SidebarModel(sections: sections())
        #expect(!model.listOptions().showsWorkspaceDirectory)
        var preferences = SidebarSectionsPreferences.defaults
        preferences.showWorkspaceDirectory = true
        model.applyListPreferences(preferences)
        #expect(model.listOptions().showsWorkspaceDirectory)
    }
}
