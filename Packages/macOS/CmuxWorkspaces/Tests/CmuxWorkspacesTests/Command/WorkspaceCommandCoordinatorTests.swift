import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class CommandStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String
    var title: String

    init(id: UUID = UUID(), isPinned: Bool = false, title: String = "") {
        self.id = id
        self.groupId = nil
        self.isPinned = isPinned
        self.currentDirectory = "/tmp"
        self.title = title
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
}

/// Minimal `WorkspacesHosting` so the model's selection didSet has somewhere to
/// fire; records nothing the command tests need.
@MainActor
private final class NoopWorkspacesHost: WorkspacesHosting {
    typealias Tab = CommandStubTab
    func workspaceTabsWillChange(to newValue: [CommandStubTab]) {}
    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {}
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {}
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {}
}

@MainActor
private final class NoopOrderHost: WorkspaceOrderHosting {
    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {}
}

@MainActor
private final class RecordingCommandHost: WorkspaceCommandHosting {
    var selectedWorkspaceHasCustomTitle = false
    var selectedWorkspacePinToggleLabel = "Pin Workspace"
    var selectedWorkspaceCanTogglePin = true
    var markReadable = true
    var markUnreadable = true
    var targets: [WorkspaceCommandWindowTarget] = []

    private(set) var pinToggles = 0
    private(set) var clearedCustomName = 0
    /// Workspace ids re-selected after a reorder. The production conformance
    /// routes these through the legacy `selectWorkspace(_ workspace: Workspace)`
    /// overload (-> `.explicitWorkspaceResume` notification dismissal); the fake
    /// only records that the resume call fired with the moved id, so a regression
    /// to the no-op bare-UUID setter shows up as an empty list here.
    private(set) var resumedAfterReorder: [UUID] = []
    private(set) var closedCurrent = 0
    private(set) var closedLists: [(ids: [UUID], allowPinned: Bool)] = []
    private(set) var movedToWindow: [(workspace: UUID, window: UUID)] = []
    private(set) var movedToNewWindow: [UUID] = []
    private(set) var markedRead: [UUID] = []
    private(set) var markedUnread: [UUID] = []
    private(set) var renameRequests = 0
    private(set) var editRequests = 0

    func toggleSelectedWorkspacePin() { pinToggles += 1 }
    func clearSelectedWorkspaceCustomName() { clearedCustomName += 1 }
    func resumeWorkspaceSelectionAfterReorder(_ workspaceId: UUID) {
        resumedAfterReorder.append(workspaceId)
    }
    func closeCurrentWorkspaceWithConfirmation() { closedCurrent += 1 }
    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        closedLists.append((workspaceIds, allowPinned))
    }
    func windowMoveTargets() -> [WorkspaceCommandWindowTarget] { targets }
    func moveWorkspace(_ workspaceId: UUID, toWindow windowId: UUID) {
        movedToWindow.append((workspaceId, windowId))
    }
    func moveWorkspaceToNewWindow(_ workspaceId: UUID) { movedToNewWindow.append(workspaceId) }
    func canMarkWorkspaceRead(_ workspaceId: UUID) -> Bool { markReadable }
    func canMarkWorkspaceUnread(_ workspaceId: UUID) -> Bool { markUnreadable }
    func markWorkspaceRead(_ workspaceId: UUID) { markedRead.append(workspaceId) }
    func markWorkspaceUnread(_ workspaceId: UUID) { markedUnread.append(workspaceId) }
    func requestRenameSelectedWorkspace() { renameRequests += 1 }
    func requestEditSelectedWorkspaceDescription() { editRequests += 1 }
}

@MainActor
private struct Fixture {
    let model: WorkspacesModel<CommandStubTab>
    let coordinator: WorkspaceCommandCoordinator<CommandStubTab>
    let host: RecordingCommandHost
    let tabs: [CommandStubTab]
    private let workspacesHost = NoopWorkspacesHost()
    private let orderHost = NoopOrderHost()

    init(count: Int = 4, selectedIndex: Int? = 1) {
        let model = WorkspacesModel<CommandStubTab>()
        model.attach(host: workspacesHost)
        let tabs = (0..<count).map { CommandStubTab(title: "ws\($0)") }
        model.tabs = tabs
        if let selectedIndex { model.selectedTabId = tabs[selectedIndex].id }
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: orderHost)
        let coordinator = WorkspaceCommandCoordinator(model: model, reordering: reorder)
        let host = RecordingCommandHost()
        coordinator.attach(host: host)
        self.model = model
        self.coordinator = coordinator
        self.host = host
        self.tabs = tabs
    }
}

@MainActor
struct WorkspaceCommandCoordinatorTests {
    @Test
    func selectedWorkspaceIndexMatchesModelOrder() {
        let f = Fixture()
        #expect(f.coordinator.selectedWorkspaceIndex(workspaceId: f.tabs[2].id) == 2)
        #expect(f.coordinator.selectedWorkspaceIndex(workspaceId: UUID()) == nil)
    }

    @Test
    func menuStateEnablementMatchesLegacyPredicatesMiddleSelection() {
        let f = Fixture(count: 4, selectedIndex: 1)
        let state = f.coordinator.menuState()
        #expect(state.hasSelectedWorkspace)
        #expect(state.selectedWorkspaceIndex == 1)
        #expect(state.workspaceCount == 4)
        #expect(state.canMoveUp)        // index 1 != 0
        #expect(state.canMoveDown)      // index 1 != 3
        #expect(state.canMoveToTop)     // selected and index != 0
        #expect(state.canCloseOthers)   // selected and count > 1
        #expect(state.canCloseBelow)
        #expect(state.canCloseAbove)
    }

    @Test
    func menuStateBoundariesAtTopAndBottom() {
        let topFixture = Fixture(count: 3, selectedIndex: 0)
        let top = topFixture.coordinator.menuState()
        #expect(!top.canMoveUp)
        #expect(top.canMoveDown)
        #expect(!top.canMoveToTop)
        #expect(!top.canCloseAbove)
        #expect(top.canCloseBelow)

        let bottomFixture = Fixture(count: 3, selectedIndex: 2)
        let bottom = bottomFixture.coordinator.menuState()
        #expect(bottom.canMoveUp)
        #expect(!bottom.canMoveDown)
        #expect(bottom.canMoveToTop)
        #expect(bottom.canCloseAbove)
        #expect(!bottom.canCloseBelow)
    }

    @Test
    func menuStateNoSelectionDisablesEverything() {
        let f = Fixture(count: 3, selectedIndex: nil)
        let state = f.coordinator.menuState()
        #expect(!state.hasSelectedWorkspace)
        #expect(state.selectedWorkspaceIndex == nil)
        #expect(!state.canMoveUp)
        #expect(!state.canMoveDown)
        #expect(!state.canMoveToTop)
        #expect(!state.canCloseOthers)
        #expect(!state.canCloseAbove)
        #expect(!state.canCloseBelow)
    }

    @Test
    func menuStateStaleSelectionResolvesAsNoSelection() {
        // Legacy gated on `manager.selectedWorkspace` (tabs.first(where:)), so a
        // selectedTabId absent from tabs disabled every selection-scoped item.
        // Pin the invariant: the resolved selection must yield no selection.
        let f = Fixture(count: 3, selectedIndex: 1)
        f.model.selectedTabId = UUID()   // id not present in tabs
        let state = f.coordinator.menuState()
        #expect(!state.hasSelectedWorkspace)
        #expect(state.selectedWorkspaceIndex == nil)
        #expect(!state.canMoveUp)
        #expect(!state.canMoveDown)
        #expect(!state.canMoveToTop)
        #expect(!state.canCloseOthers)
        #expect(!state.canCloseAbove)
        #expect(!state.canCloseBelow)
    }

    @Test
    func menuStateSingleWorkspaceDisablesCloseOthers() {
        let f = Fixture(count: 1, selectedIndex: 0)
        let state = f.coordinator.menuState()
        #expect(state.hasSelectedWorkspace)
        #expect(!state.canCloseOthers)   // count <= 1
    }

    @Test
    func closeOtherPeersExcludesSelected() {
        let f = Fixture(count: 4, selectedIndex: 1)
        f.coordinator.closeOtherSelectedWorkspacePeers()
        let call = f.host.closedLists.first
        #expect(call?.ids == [f.tabs[0].id, f.tabs[2].id, f.tabs[3].id])
        #expect(call?.allowPinned == true)
    }

    @Test
    func closeBelowTakesSuffixAfterAnchor() {
        let f = Fixture(count: 4, selectedIndex: 1)
        f.coordinator.closeSelectedWorkspacesBelow()
        #expect(f.host.closedLists.first?.ids == [f.tabs[2].id, f.tabs[3].id])
    }

    @Test
    func closeAboveTakesPrefixBeforeAnchor() {
        let f = Fixture(count: 4, selectedIndex: 2)
        f.coordinator.closeSelectedWorkspacesAbove()
        #expect(f.host.closedLists.first?.ids == [f.tabs[0].id, f.tabs[1].id])
    }

    @Test
    func moveByDeltaReordersAndReselects() {
        let f = Fixture(count: 4, selectedIndex: 1)
        let movedId = f.tabs[1].id
        f.coordinator.moveSelectedWorkspace(by: 1)
        #expect(f.model.tabs.map(\.id)[2] == movedId)
        // Re-selection MUST route through the explicit-resume path (the moved
        // workspace is the selected one), not be dropped as a no-op.
        #expect(f.host.resumedAfterReorder == [movedId])
    }

    @Test
    func moveToTopReselectsViaResumePath() {
        let f = Fixture(count: 4, selectedIndex: 2)
        let movedId = f.tabs[2].id
        f.coordinator.moveSelectedWorkspaceToTop()
        #expect(f.model.tabs.map(\.id).first == movedId)
        #expect(f.host.resumedAfterReorder == [movedId])
    }

    @Test
    func moveByDeltaClampsOutOfRange() {
        let f = Fixture(count: 3, selectedIndex: 0)
        f.coordinator.moveSelectedWorkspace(by: -1)   // already at top
        #expect(f.model.tabs.map(\.id) == f.tabs.map(\.id))
        #expect(f.host.resumedAfterReorder.isEmpty)
    }

    @Test
    func moveToWindowAndNewWindowForwardSelectedId() {
        let f = Fixture(count: 3, selectedIndex: 1)
        let windowId = UUID()
        f.coordinator.moveSelectedWorkspace(toWindow: windowId)
        f.coordinator.moveSelectedWorkspaceToNewWindow()
        #expect(f.host.movedToWindow.first?.workspace == f.tabs[1].id)
        #expect(f.host.movedToWindow.first?.window == windowId)
        #expect(f.host.movedToNewWindow == [f.tabs[1].id])
    }

    @Test
    func markReadUnreadForwardSelectedId() {
        let f = Fixture(count: 3, selectedIndex: 2)
        f.coordinator.markSelectedWorkspaceRead()
        f.coordinator.markSelectedWorkspaceUnread()
        #expect(f.host.markedRead == [f.tabs[2].id])
        #expect(f.host.markedUnread == [f.tabs[2].id])
    }

    @Test
    func passthroughActionsForwardToHost() {
        let f = Fixture(count: 2, selectedIndex: 0)
        f.coordinator.toggleSelectedWorkspacePinned()
        f.coordinator.renameSelectedWorkspace()
        f.coordinator.editSelectedWorkspaceDescription()
        f.coordinator.clearSelectedWorkspaceCustomName()
        f.coordinator.closeSelectedWorkspace()
        #expect(f.host.pinToggles == 1)
        #expect(f.host.renameRequests == 1)
        #expect(f.host.editRequests == 1)
        #expect(f.host.clearedCustomName == 1)
        #expect(f.host.closedCurrent == 1)
    }

    @Test
    func menuStateCarriesHostResolvedValues() {
        let f = Fixture(count: 2, selectedIndex: 0)
        f.host.selectedWorkspaceHasCustomTitle = true
        f.host.selectedWorkspacePinToggleLabel = "Unpin Workspace"
        f.host.selectedWorkspaceCanTogglePin = false
        f.host.markReadable = false
        f.host.markUnreadable = true
        f.host.targets = [
            WorkspaceCommandWindowTarget(windowId: UUID(), label: "Window 2", isCurrentWindow: false),
        ]
        let state = f.coordinator.menuState()
        #expect(state.selectedWorkspaceHasCustomTitle)
        #expect(state.pinToggleLabel == "Unpin Workspace")
        #expect(!state.pinToggleEnabled)
        #expect(!state.canMarkRead)
        #expect(state.canMarkUnread)
        #expect(state.windowMoveTargets.count == 1)
    }
}
