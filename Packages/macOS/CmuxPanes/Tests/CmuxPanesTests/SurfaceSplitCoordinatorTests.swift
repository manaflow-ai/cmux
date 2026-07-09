import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

/// Verifies the lifted ``SurfaceSplitCoordinator`` commands resolve the target
/// workspace and drive the host/handle hooks in exactly the order and under
/// exactly the conditions the legacy `TabManager` surface-navigation,
/// split-creation, and split-operation bodies did, over synthetic fakes that
/// record each call.
@MainActor
struct SurfaceSplitCoordinatorTests {
    /// Records every per-workspace operation the coordinator forwards. The
    /// terminal-creation operations return a configurable created-panel id; the
    /// resize-related reads expose a live `BonsplitController` so the guard
    /// branches can be exercised.
    final class FakeWorkspace: SurfaceSplitWorkspaceHandle {
        var focusedPanelId: UUID?
        var ownedPanels: Set<UUID> = []
        var surfaceForPanel: [UUID: TabID] = [:]
        var paneForPanel: [UUID: PaneID] = [:]
        let bonsplitController = BonsplitController()

        var newSurfaceResult: UUID?
        var newSplitResult: UUID?
        var toggleZoomReturns = true

        var calls: [String] = []

        func hasPanel(_ panelId: UUID) -> Bool { ownedPanels.contains(panelId) }
        func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? { surfaceForPanel[panelId] }
        func paneId(forPanelId panelId: UUID) -> PaneID? { paneForPanel[panelId] }

        func selectNextSurface() { calls.append("selectNext") }
        func selectPreviousSurface() { calls.append("selectPrevious") }
        func selectSurface(at index: Int) { calls.append("selectAt(\(index))") }
        func selectLastSurface() { calls.append("selectLast") }

        @discardableResult
        func clearSplitZoom() -> Bool {
            calls.append("clearSplitZoom")
            return true
        }
        func surfaceSplitNewTerminalSurfaceInFocusedPane(focus: Bool, initialInput: String?) -> UUID? {
            calls.append("newSurface(focus:\(focus),input:\(initialInput ?? "nil"))")
            return newSurfaceResult
        }
        func surfaceSplitNewTerminalSplit(
            from panelId: UUID,
            orientation: SplitOrientation,
            insertFirst: Bool,
            focus: Bool,
            workingDirectory: String?,
            initialCommand: String?,
            tmuxStartCommand: String?,
            startupEnvironment: [String: String],
            initialDividerPosition: CGFloat?,
            remotePTYSessionID: String?
        ) -> UUID? {
            calls.append("newTerminalSplit(\(orientation),insertFirst:\(insertFirst),focus:\(focus))")
            return newSplitResult
        }
        func moveFocus(direction: NavigationDirection) { calls.append("moveFocus(\(direction))") }
        func toggleSplitZoom(panelId: UUID) -> Bool {
            calls.append("toggleZoom")
            return toggleZoomReturns
        }
        @discardableResult
        func closePanel(_ panelId: UUID, force: Bool) -> Bool {
            calls.append("closePanel")
            return true
        }
    }

    /// Records workspace resolution and the app-coupled breadcrumb/notification
    /// effects, mapping ids to the fake workspaces under test.
    final class FakeHost: SurfaceSplitHosting {
        var selectedWorkspaceId: UUID?
        var workspaces: [UUID: FakeWorkspace] = [:]
        var calls: [String] = []

        func surfaceSplitWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any SurfaceSplitWorkspaceHandle)? {
            workspaces[workspaceId]
        }
        var selectedSurfaceSplitWorkspaceHandle: (any SurfaceSplitWorkspaceHandle)? {
            guard let selectedWorkspaceId else { return nil }
            return workspaces[selectedWorkspaceId]
        }
        func recordSplitCreateBreadcrumb(direction: String) {
            calls.append("breadcrumb(\(direction))")
        }
        func clearNotifications(forWorkspaceId workspaceId: UUID, surfaceId: UUID) {
            calls.append("clearNotifications")
        }
    }

    private func makeCoordinator(_ host: FakeHost) -> SurfaceSplitCoordinator {
        let coordinator = SurfaceSplitCoordinator()
        coordinator.attach(host: host)
        return coordinator
    }

    // MARK: Surface navigation

    @Test func navigationForwardsToSelectedWorkspace() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id
        let c = makeCoordinator(host)

        c.selectNextSurface()
        c.selectPreviousSurface()
        c.selectSurface(at: 4)
        c.selectLastSurface()
        #expect(ws.calls == ["selectNext", "selectPrevious", "selectAt(4)", "selectLast"])
    }

    @Test func navigationNoOpsWhenNoSelectedWorkspace() {
        let host = FakeHost()  // no selection
        let c = makeCoordinator(host)
        c.selectNextSurface()
        c.selectLastSurface()
        #expect(host.calls.isEmpty)
    }

    // MARK: newSurface

    @Test func newSurfaceClearsZoomThenCreatesFocusedSurface() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id

        makeCoordinator(host).newSurface()
        #expect(ws.calls == ["clearSplitZoom", "newSurface(focus:true,input:nil)"])
    }

    @Test func newSurfaceWithInitialInputThreadsTheInput() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id

        makeCoordinator(host).newSurface(initialInput: "echo hi")
        #expect(ws.calls == ["clearSplitZoom", "newSurface(focus:true,input:echo hi)"])
    }

    // MARK: createSplit

    @Test func createSplitFromSelectedResolvesFocusedPanelAndCreates() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        let panel = UUID()
        ws.focusedPanelId = panel
        ws.ownedPanels = [panel]
        ws.newSplitResult = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id

        let created = makeCoordinator(host).createSplit(direction: .right)
        #expect(created == ws.newSplitResult)
        #expect(ws.calls == ["clearSplitZoom", "newTerminalSplit(\(SplitOrientation.horizontal),insertFirst:false,focus:true)"])
        #expect(host.calls == ["breadcrumb(right)"])
    }

    @Test func createSplitFromSelectedReturnsNilWhenNoFocusedPanel() {
        let host = FakeHost()
        let ws = FakeWorkspace()  // no focusedPanelId
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id

        #expect(makeCoordinator(host).createSplit(direction: .down) == nil)
        #expect(ws.calls.isEmpty)
        #expect(host.calls.isEmpty)
    }

    @Test func createSplitExplicitReturnsNilWhenPanelAbsent() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]
        // surfaceId not in ownedPanels -> guard fails before any effect.
        #expect(makeCoordinator(host).createSplit(tabId: id, surfaceId: UUID(), direction: .left) == nil)
        #expect(ws.calls.isEmpty)
        #expect(host.calls.isEmpty)
    }

    // MARK: moveSplitFocus / toggleSplitZoom / toggleFocusedSplitZoom

    @Test func moveSplitFocusForwardsWhenWorkspaceResolves() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]

        #expect(makeCoordinator(host).moveSplitFocus(tabId: id, surfaceId: UUID(), direction: .left))
        #expect(ws.calls == ["moveFocus(\(NavigationDirection.left))"])
    }

    @Test func moveSplitFocusFalseWhenWorkspaceMissing() {
        let host = FakeHost()
        #expect(makeCoordinator(host).moveSplitFocus(tabId: UUID(), surfaceId: UUID(), direction: .up) == false)
    }

    @Test func toggleSplitZoomForwardsResult() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        ws.toggleZoomReturns = false
        let id = UUID()
        host.workspaces = [id: ws]
        #expect(makeCoordinator(host).toggleSplitZoom(tabId: id, surfaceId: UUID()) == false)
        #expect(ws.calls == ["toggleZoom"])
    }

    @Test func toggleFocusedSplitZoomUsesSelectedWorkspaceFocusedPanel() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        ws.focusedPanelId = UUID()
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id
        #expect(makeCoordinator(host).toggleFocusedSplitZoom())
        #expect(ws.calls == ["toggleZoom"])
    }

    @Test func toggleFocusedSplitZoomFalseWhenNoFocusedPanel() {
        let host = FakeHost()
        let ws = FakeWorkspace()  // no focusedPanelId
        let id = UUID()
        host.workspaces = [id: ws]
        host.selectedWorkspaceId = id
        #expect(makeCoordinator(host).toggleFocusedSplitZoom() == false)
        #expect(ws.calls.isEmpty)
    }

    // MARK: resizeSplit guards

    @Test func resizeSplitFalseOnZeroAmountOrMissingWorkspaceOrMissingPane() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host.workspaces = [id: ws]

        // amount == 0
        #expect(makeCoordinator(host).resizeSplit(tabId: id, surfaceId: UUID(), direction: .right, amount: 0) == false)
        // missing workspace
        #expect(makeCoordinator(host).resizeSplit(tabId: UUID(), surfaceId: UUID(), direction: .right, amount: 5) == false)
        // workspace resolves but panel has no pane mapping
        #expect(makeCoordinator(host).resizeSplit(tabId: id, surfaceId: UUID(), direction: .right, amount: 5) == false)
    }

    // MARK: closeSurface

    @Test func closeSurfaceClosesPanelAndClearsNotificationsWhenLive() {
        let host = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        let panel = UUID()
        ws.ownedPanels = [panel]
        ws.surfaceForPanel = [panel: TabID(uuid: UUID())]
        host.workspaces = [id: ws]

        #expect(makeCoordinator(host).closeSurface(tabId: id, surfaceId: panel))
        #expect(ws.calls == ["closePanel"])
        #expect(host.calls == ["clearNotifications"])
    }

    @Test func closeSurfaceFalseWhenStaleOrUnowned() {
        // Workspace missing.
        let host = FakeHost()
        #expect(makeCoordinator(host).closeSurface(tabId: UUID(), surfaceId: UUID()) == false)

        // Panel not owned (stale close).
        let host2 = FakeHost()
        let ws = FakeWorkspace()
        let id = UUID()
        host2.workspaces = [id: ws]
        #expect(makeCoordinator(host2).closeSurface(tabId: id, surfaceId: UUID()) == false)
        #expect(ws.calls.isEmpty)
        #expect(host2.calls.isEmpty)
    }
}
