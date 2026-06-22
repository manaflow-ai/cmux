import Foundation
import Testing
import Bonsplit
@testable import CmuxWorkspaces

/// Behavior tests for ``PaneSurfaceMoveCoordinator``: the move-target projection
/// and the same-workspace-split / same-workspace-move / cross-workspace path
/// selection lifted from the legacy `AppDelegate.moveSurface`/`moveBonsplitTab`/
/// `workspaceMoveTargets` bodies. A recording fake host stands in for the live
/// `Workspace`/`TabManager` mutations so the decision is exercised in isolation.
@MainActor
@Suite struct PaneSurfaceMoveCoordinatorTests {
    /// Records every host call so the test can assert which path the coordinator
    /// chose, in order, with the resolved values it passed.
    final class RecordingHost: PaneSurfaceMoveHosting {
        enum Call: Equatable {
            case resolveSourceLocation(UUID)
            case resolveBonsplit(UUID)
            case workspaceExists(UUID)
            case windowId(UUID)
            case resolveTargetPane(workspace: UUID, requested: PaneID?)
            case splitSame(workspace: UUID, panel: UUID, pane: PaneID, orientation: SplitOrientation, insertFirst: Bool, focus: Bool)
            case moveSame(workspace: UUID, panel: UUID, pane: PaneID, index: Int?, focus: Bool)
            case crossWorkspace(panel: UUID, sourceWorkspace: UUID, sourceWindow: UUID, plan: PaneSurfaceMoveCrossWorkspacePlan)
        }

        var calls: [Call] = []

        var locateSurfaceResult: PaneSurfaceMoveSourceLocation?
        var locateBonsplitResult: (location: PaneSurfaceMoveSourceLocation, panelId: UUID)?
        var workspaceExistsResult = true
        var windowIdResult: UUID?
        var resolveTargetPaneResult: PaneID?
        var splitSameResult = true
        var moveSameResult = true
        var crossWorkspaceResult = true

        func resolveSourceLocation(surfaceId: UUID) -> PaneSurfaceMoveSourceLocation? {
            calls.append(.resolveSourceLocation(surfaceId))
            return locateSurfaceResult
        }
        func resolveBonsplitLocation(tabId: UUID) -> (location: PaneSurfaceMoveSourceLocation, panelId: UUID)? {
            calls.append(.resolveBonsplit(tabId))
            return locateBonsplitResult
        }
        func workspaceExists(_ workspaceId: UUID) -> Bool {
            calls.append(.workspaceExists(workspaceId))
            return workspaceExistsResult
        }
        func windowId(forWorkspace workspaceId: UUID) -> UUID? {
            calls.append(.windowId(workspaceId))
            return windowIdResult
        }
        func resolveTargetPane(inWorkspace workspaceId: UUID, requested targetPane: PaneID?) -> PaneID? {
            calls.append(.resolveTargetPane(workspace: workspaceId, requested: targetPane))
            return resolveTargetPaneResult
        }
        func splitSameWorkspace(workspaceId: UUID, panelId: UUID, targetPane: PaneID, orientation: SplitOrientation, insertFirst: Bool, focus: Bool) -> Bool {
            calls.append(.splitSame(workspace: workspaceId, panel: panelId, pane: targetPane, orientation: orientation, insertFirst: insertFirst, focus: focus))
            return splitSameResult
        }
        func moveSameWorkspace(workspaceId: UUID, panelId: UUID, targetPane: PaneID, atIndex index: Int?, focus: Bool) -> Bool {
            calls.append(.moveSame(workspace: workspaceId, panel: panelId, pane: targetPane, index: index, focus: focus))
            return moveSameResult
        }
        func performCrossWorkspaceMove(panelId: UUID, sourceWorkspaceId: UUID, sourceWindowId: UUID, plan: PaneSurfaceMoveCrossWorkspacePlan) -> Bool {
            calls.append(.crossWorkspace(panel: panelId, sourceWorkspace: sourceWorkspaceId, sourceWindow: sourceWindowId, plan: plan))
            return crossWorkspaceResult
        }
    }

    private func makeCoordinator() -> (PaneSurfaceMoveCoordinator, RecordingHost) {
        let host = RecordingHost()
        let coordinator = PaneSurfaceMoveCoordinator()
        coordinator.attach(host: host)
        return (coordinator, host)
    }

    @Test func moveTargetsExcludesAndProjects() {
        let (coordinator, _) = makeCoordinator()
        let winA = UUID(), winB = UUID()
        let wsA1 = UUID(), wsA2 = UUID(), wsB1 = UUID()
        let summaries = [
            PaneSurfaceMoveWindowSummary(
                windowId: winA, windowLabel: "Current Window", isCurrentWindow: true,
                workspaces: [
                    .init(workspaceId: wsA1, title: "Alpha"),
                    .init(workspaceId: wsA2, title: "Beta"),
                ]
            ),
            PaneSurfaceMoveWindowSummary(
                windowId: winB, windowLabel: "Window 2", isCurrentWindow: false,
                workspaces: [.init(workspaceId: wsB1, title: "Gamma")]
            ),
        ]
        let targets = coordinator.moveTargets(for: summaries, excludingWorkspaceId: wsA1)
        #expect(targets.count == 2)
        #expect(targets[0].workspaceId == wsA2)
        #expect(targets[0].label == "Beta")
        #expect(targets[1].workspaceId == wsB1)
        // Cross-window target shows the window label in parentheses.
        #expect(targets[1].label == "Gamma (Window 2)")
    }

    @Test func sameWorkspaceSplitTakesSplitPath() {
        let (coordinator, host) = makeCoordinator()
        let ws = UUID(), panel = UUID(), pane = PaneID()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: ws)
        host.resolveTargetPaneResult = pane
        let ok = coordinator.move(surface: PaneSurfaceMoveRequest(
            panelId: panel,
            targetWorkspaceId: ws,
            splitTarget: .init(orientation: .horizontal, insertFirst: true)
        ))
        #expect(ok)
        #expect(host.calls.contains(.splitSame(workspace: ws, panel: panel, pane: pane, orientation: .horizontal, insertFirst: true, focus: true)))
        #expect(!host.calls.contains(where: { if case .crossWorkspace = $0 { return true } else { return false } }))
    }

    @Test func sameWorkspaceNoSplitTakesMovePath() {
        let (coordinator, host) = makeCoordinator()
        let ws = UUID(), panel = UUID(), pane = PaneID()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: ws)
        host.resolveTargetPaneResult = pane
        _ = coordinator.move(surface: PaneSurfaceMoveRequest(panelId: panel, targetWorkspaceId: ws, targetIndex: 3))
        #expect(host.calls.contains(.moveSame(workspace: ws, panel: panel, pane: pane, index: 3, focus: true)))
    }

    @Test func crossWorkspaceBuildsPlanWithDestinationWindow() {
        let (coordinator, host) = makeCoordinator()
        let srcWs = UUID(), srcWin = UUID(), dstWs = UUID(), dstWin = UUID()
        let panel = UUID(), pane = PaneID()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: srcWin, workspaceId: srcWs)
        host.resolveTargetPaneResult = pane
        host.windowIdResult = dstWin
        let ok = coordinator.move(surface: PaneSurfaceMoveRequest(panelId: panel, targetWorkspaceId: dstWs))
        #expect(ok)
        let expectedPlan = PaneSurfaceMoveCrossWorkspacePlan(
            destinationWorkspaceId: dstWs, destinationWindowId: dstWin,
            targetPane: pane, targetIndex: nil, splitTarget: nil, focus: true
        )
        #expect(host.calls.contains(.crossWorkspace(panel: panel, sourceWorkspace: srcWs, sourceWindow: srcWin, plan: expectedPlan)))
    }

    @Test func crossWorkspaceOmitsDestinationWindowWhenFocusWindowFalse() {
        let (coordinator, host) = makeCoordinator()
        let srcWs = UUID(), dstWs = UUID(), panel = UUID(), pane = PaneID()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: srcWs)
        host.resolveTargetPaneResult = pane
        _ = coordinator.move(surface: PaneSurfaceMoveRequest(panelId: panel, targetWorkspaceId: dstWs, focusWindow: false))
        // windowId(forWorkspace:) must NOT be consulted when focusWindow is false.
        #expect(!host.calls.contains(.windowId(dstWs)))
        let plan = host.calls.compactMap { call -> PaneSurfaceMoveCrossWorkspacePlan? in
            if case .crossWorkspace(_, _, _, let p) = call { return p } else { return nil }
        }.first
        #expect(plan?.destinationWindowId == nil)
    }

    @Test func failsWhenSourceNotFound() {
        let (coordinator, host) = makeCoordinator()
        host.locateSurfaceResult = nil
        #expect(!coordinator.move(surface: PaneSurfaceMoveRequest(panelId: UUID(), targetWorkspaceId: UUID())))
    }

    @Test func failsWhenDestinationWorkspaceMissing() {
        let (coordinator, host) = makeCoordinator()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: UUID())
        host.workspaceExistsResult = false
        #expect(!coordinator.move(surface: PaneSurfaceMoveRequest(panelId: UUID(), targetWorkspaceId: UUID())))
    }

    @Test func failsWhenTargetPaneUnresolved() {
        let (coordinator, host) = makeCoordinator()
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: UUID())
        host.resolveTargetPaneResult = nil
        #expect(!coordinator.move(surface: PaneSurfaceMoveRequest(panelId: UUID(), targetWorkspaceId: UUID())))
    }

    @Test func moveBonsplitTabResolvesPanelThenMoves() {
        let (coordinator, host) = makeCoordinator()
        let tab = UUID(), panel = UUID(), ws = UUID(), pane = PaneID()
        host.locateBonsplitResult = (PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: ws), panel)
        host.locateSurfaceResult = PaneSurfaceMoveSourceLocation(windowId: UUID(), workspaceId: ws)
        host.resolveTargetPaneResult = pane
        let ok = coordinator.moveBonsplitTab(
            tabId: tab, toWorkspace: ws, targetPane: nil, targetIndex: nil,
            splitTarget: nil, focus: true, focusWindow: true
        )
        #expect(ok)
        #expect(host.calls.first == .resolveBonsplit(tab))
    }

    @Test func moveBonsplitTabFailsWhenTabNotFound() {
        let (coordinator, host) = makeCoordinator()
        host.locateBonsplitResult = nil
        #expect(!coordinator.moveBonsplitTab(
            tabId: UUID(), toWorkspace: UUID(), targetPane: nil, targetIndex: nil,
            splitTarget: nil, focus: true, focusWindow: true
        ))
    }
}
