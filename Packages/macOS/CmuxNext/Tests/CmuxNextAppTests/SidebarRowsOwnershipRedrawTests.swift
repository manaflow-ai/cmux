@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/25776: a Pinned or custom group leaves a window when another window lists
/// its open workspace. That answer changes with window ownership alone (a new workspace given to the other window),
/// with no row of this window changing, so a pass that lists the same rows still shows again when it changes.
@MainActor @Suite(.serialized) struct SidebarRowsOwnershipRedrawTests {
    static let live = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                      nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "ws-1"))])]

    @Test func theSameRowsShowAgainWhenOnlyTheGroupsListedElsewhereChange() {
        let model = SidebarModel(sections: [])
        let rows = SidebarRows(model: model)
        rows.show(Self.live, creating: ([], nil), unlessShown: true, elsewhere: [])
        #expect(model.sections.flatMap(\.workspaces).map(\.id.rawValue) == ["ws-1"])
        model.setSections([]) // a marker: a skipped pass leaves it
        rows.show(Self.live, creating: ([], nil), unlessShown: true, elsewhere: [])
        #expect(model.sections.isEmpty, "the same rows and owners showed again")
        rows.show(Self.live, creating: ([], nil), unlessShown: true, elsewhere: ["itm_g"])
        #expect(model.sections.flatMap(\.workspaces).map(\.id.rawValue) == ["ws-1"], "a change of owners alone did not show again")
    }
}
