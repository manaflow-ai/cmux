@testable import CmuxNextSidebar
import Testing

@MainActor
struct SidebarCloseSelectionTests {
    private static func model(active: Int = 1) -> (SidebarModel, [WorkspaceID]) {
        let ids = (0..<4).map { WorkspaceID("workspace-\($0)") }
        let workspaces = ids.enumerated().map { SidebarWorkspace(id: $0.element, title: "Workspace \($0.offset)") }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(
            sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
            activeWorkspaceID: ids[active]
        )
        return (model, ids)
    }

    @Test func closingMiddleSelectsTheNextWorkspace() {
        let (model, ids) = Self.model(active: 1)
        model.apply(.close([ids[1]]))
        #expect(model.activeWorkspaceID == ids[2])
        #expect(model.selection == Set([ids[2]]))
    }

    @Test func closingLastSelectsThePreviousWorkspace() {
        let (model, ids) = Self.model(active: 3)
        model.apply(.close([ids[3]]))
        #expect(model.activeWorkspaceID == ids[2])
        #expect(model.selection == Set([ids[2]]))
    }

    @Test func closingSeveralUsesTheFirstSurvivingSuccessor() {
        let (model, ids) = Self.model(active: 2)
        model.apply(.close([ids[1], ids[2]]))
        #expect(model.activeWorkspaceID == ids[3])
        #expect(model.selection == Set([ids[3]]))
    }

    @Test func closingASelectedRowClosesTheWholeSelectionInRowOrder() {
        let (model, ids) = Self.model(active: 1)
        model.selection = [ids[3], ids[1], ids[2]]
        #expect(model.closeTargets(for: ids[2]) == [ids[1], ids[2], ids[3]])
    }

    @Test func closingARowOutsideTheSelectionClosesOnlyThatRow() {
        let (model, ids) = Self.model(active: 1)
        model.selection = [ids[1], ids[2]]
        #expect(model.closeTargets(for: ids[0]) == [ids[0]])
    }

    @Test func closingTheOnlySelectedRowClosesOnlyThatRow() {
        let (model, ids) = Self.model(active: 1)
        #expect(model.closeTargets(for: ids[1]) == [ids[1]])
    }

    @Test func closingAWholeSelectionSelectsTheRowAfterIt() {
        let (model, ids) = Self.model(active: 1)
        model.selection = [ids[1], ids[2]]
        model.apply(.close(model.closeTargets(for: ids[1])))
        #expect(model.activeWorkspaceID == ids[3])
        #expect(model.selection == Set([ids[3]]))
    }

    @Test func closingAnUnfocusedWorkspaceKeepsFocus() {
        let (model, ids) = Self.model(active: 1)
        model.apply(.close([ids[3]]))
        #expect(model.activeWorkspaceID == ids[1])
        #expect(model.selection == Set([ids[1]]))
    }
}
