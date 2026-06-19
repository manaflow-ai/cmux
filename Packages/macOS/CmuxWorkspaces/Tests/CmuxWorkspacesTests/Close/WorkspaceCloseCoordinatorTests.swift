import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class StubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String

    init(
        id: UUID = UUID(),
        isPinned: Bool = false,
        title: String = ""
    ) {
        self.id = id
        self.isPinned = isPinned
        self.currentDirectory = "/tmp"
        self.title = title
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
}

/// Records the strings the coordinator asks for so the plan assembly can be
/// asserted without the app bundle's real localized catalog.
@MainActor
private final class StubConfirming: CloseConfirming {
    var confirmResult = true
    private(set) var confirmCalls: [(title: String, message: String, acceptCmdD: Bool)] = []

    func closeWorkspacesTitle(willCloseWindow: Bool) -> String {
        willCloseWindow ? "WINDOW_TITLE" : "WORKSPACES_TITLE"
    }

    func closeWorkspacesMessage(
        willCloseWindow: Bool,
        workspaceCount: Int,
        bulletedTitles: String
    ) -> String {
        "\(willCloseWindow ? "WINDOW" : "WS")|\(workspaceCount)|\(bulletedTitles)"
    }

    var workspaceDisplayTitleFallback: String { "FALLBACK" }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        confirmCalls.append((title, message, acceptCmdD))
        return confirmResult
    }
}

@MainActor
private func makeCoordinator(
    tabs: [StubTab],
    selected: UUID? = nil
) -> (WorkspaceCloseCoordinator<StubTab>, StubConfirming) {
    let model = WorkspacesModel<StubTab>()
    model.tabs = tabs
    model.selectedTabId = selected
    let coordinator = WorkspaceCloseCoordinator(model: model)
    let confirming = StubConfirming()
    coordinator.attach(confirming: confirming)
    return (coordinator, confirming)
}

@MainActor
@Suite("WorkspaceCloseCoordinator")
struct WorkspaceCloseCoordinatorTests {
    @Test
    func orderedClosableWorkspacesPreservesSidebarOrderAndDropsUnknownAndPinned() {
        let a = StubTab(title: "a")
        let b = StubTab(isPinned: true, title: "b")
        let c = StubTab(title: "c")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        let unknown = UUID()

        // Request order is c,a,unknown,b but result follows sidebar order a,b,c
        // and excludes the pinned b (allowPinned=false) and the unknown id.
        let result = coordinator.orderedClosableWorkspaces(
            [c.id, a.id, unknown, b.id],
            allowPinned: false
        )
        #expect(result.map(\.id) == [a.id, c.id])

        // allowPinned=true keeps the pinned workspace, still in sidebar order.
        let withPinned = coordinator.orderedClosableWorkspaces(
            [c.id, a.id, b.id],
            allowPinned: true
        )
        #expect(withPinned.map(\.id) == [a.id, b.id, c.id])
    }

    @Test
    func orderedSidebarSelectedWorkspaceIdsIntersectsInSidebarOrder() {
        let a = StubTab()
        let b = StubTab()
        let c = StubTab()
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        let unknown = UUID()

        let result = coordinator.orderedSidebarSelectedWorkspaceIds(
            sidebarSelectedWorkspaceIds: [c.id, a.id, unknown]
        )
        #expect(result == [a.id, c.id])
    }

    @Test
    func closeWorkspacesPlanWindowVariantWhenClosingEveryWorkspace() {
        let a = StubTab(title: "a")
        let b = StubTab(title: "b")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b])
        _ = confirming // retain the weakly-held seam for the test's lifetime

        let plan = coordinator.closeWorkspacesPlan(for: [a, b])
        #expect(plan != nil)
        #expect(plan?.willCloseWindow == true)
        #expect(plan?.acceptCmdD == true)
        #expect(plan?.workspaceIds == [a.id, b.id])
        #expect(plan?.title == "WINDOW_TITLE")
        // 2 workspaces, bulleted titles preserve order and the "• " prefix.
        #expect(plan?.message == "WINDOW|2|• a\n• b")
    }

    @Test
    func closeWorkspacesPlanSubsetVariantAndEmptyTitleFallback() {
        let a = StubTab(title: "  spaced  ")
        let b = StubTab(title: "")
        let c = StubTab(title: "c")
        let (coordinator, confirming) = makeCoordinator(tabs: [a, b, c])
        _ = confirming // retain the weakly-held seam for the test's lifetime

        // Close two of three -> not the whole window.
        let plan = coordinator.closeWorkspacesPlan(for: [a, b])
        #expect(plan?.willCloseWindow == false)
        #expect(plan?.acceptCmdD == false)
        #expect(plan?.title == "WORKSPACES_TITLE")
        // a's title is whitespace-collapsed; b's empty title becomes FALLBACK.
        #expect(plan?.message == "WS|2|• spaced\n• FALLBACK")
    }

    @Test
    func closeWorkspaceDisplayTitleCollapsesNewlinesAndUsesFallback() {
        let (coordinator, confirming) = makeCoordinator(tabs: [])
        _ = confirming // retain the weakly-held seam for the test's lifetime
        #expect(coordinator.closeWorkspaceDisplayTitle("one\ntwo\rthree") == "one two three")
        #expect(coordinator.closeWorkspaceDisplayTitle("   ") == "FALLBACK")
        #expect(coordinator.closeWorkspaceDisplayTitle(nil) == "FALLBACK")
    }

    @Test
    func planIsNilWhenConfirmingNotAttached() {
        let model = WorkspacesModel<StubTab>()
        let a = StubTab(title: "a")
        model.tabs = [a]
        let coordinator = WorkspaceCloseCoordinator(model: model)
        #expect(coordinator.closeWorkspacesPlan(for: [a]) == nil)
    }
}
