import Testing
@testable import CmuxWorkspaces

@MainActor
struct WorkspaceColorCoordinatorTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        return (model, reorder)
    }

    @Test
    func setTabColorMutatesOnlyTheNamedWorkspace() {
        let (model, reorder) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]

        reorder.setTabColor(tabId: a.id, color: "#112233")

        #expect(a.customColor == "#112233")
        #expect(b.customColor == nil)
    }

    @Test
    func applyWorkspaceColorMultiTargetSetsAndClearsEachMatch() {
        let (model, reorder) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]

        reorder.applyWorkspaceColor("#ABCDEF", toWorkspaceIds: [a.id, c.id])
        #expect(a.customColor == "#ABCDEF")
        #expect(b.customColor == nil)
        #expect(c.customColor == "#ABCDEF")

        reorder.applyWorkspaceColor(nil, toWorkspaceIds: [a.id, c.id])
        #expect(a.customColor == nil)
        #expect(c.customColor == nil)
    }
}
