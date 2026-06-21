import Bonsplit
import CmuxCanvas
import CmuxCanvasUI
import CmuxControlSocket
import Foundation

/// Canvas-domain witnesses. Reads snapshot the workspace's `canvasModel`;
/// mutations route through `CanvasActionExecutor` / the model so the socket
/// shares one execution path with shortcuts, the palette, and the View menu.
extension TerminalController: ControlCanvasContext {
    /// The routing twin used by every canvas verb: TabManager, then workspace.
    func resolveCanvasWorkspace(routing: ControlRoutingSelectors) -> Workspace? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    func controlCanvasInfo(routing: ControlRoutingSelectors) -> ControlCanvasInfoSnapshot? {
        guard let ws = resolveCanvasWorkspace(routing: routing) else { return nil }
        let focusedPanelId = ws.focusedPanelId
        let panes: [ControlCanvasPaneSummary]
        if ws.layoutMode == .zoomableSplits {
            let snapshot = ws.bonsplitController.layoutSnapshot()
            panes = snapshot.panes.compactMap { pane in
                let panelIDs = pane.tabIds.compactMap { UUID(uuidString: $0) }
                    .compactMap { ws.panelIdFromSurfaceId(TabID(uuid: $0)) }
                guard !panelIDs.isEmpty else { return nil }
                let selectedPanelID = pane.selectedTabId
                    .flatMap { UUID(uuidString: $0) }
                    .flatMap { ws.panelIdFromSurfaceId(TabID(uuid: $0)) }
                    ?? panelIDs[0]
                return ControlCanvasPaneSummary(
                    surfaceID: selectedPanelID,
                    frame: ControlCanvasFrame(
                        x: pane.frame.x - snapshot.containerFrame.x,
                        y: pane.frame.y - snapshot.containerFrame.y,
                        width: pane.frame.width,
                        height: pane.frame.height
                    ),
                    isFocused: focusedPanelId.map(panelIDs.contains) ?? false,
                    panelIDs: panelIDs,
                    selectedPanelID: selectedPanelID
                )
            }
        } else {
            panes = ws.canvasModel.layout.panes.map { pane in
                let panelIDs = pane.panelIds.map(\.rawValue)
                return ControlCanvasPaneSummary(
                    surfaceID: pane.id.rawValue,
                    frame: ControlCanvasFrame(
                        x: pane.frame.x,
                        y: pane.frame.y,
                        width: pane.frame.width,
                        height: pane.frame.height
                    ),
                    isFocused: focusedPanelId.map(panelIDs.contains) ?? false,
                    panelIDs: panelIDs,
                    selectedPanelID: pane.selectedPanelId.rawValue
                )
            }
        }
        var magnification: Double?
        var centerX: Double?
        var centerY: Double?
        if let viewport = activeViewport(for: ws) {
            magnification = Double(viewport.currentMagnification)
            let center = viewport.currentCenterInCanvas
            centerX = Double(center.x)
            centerY = Double(center.y)
        }
        return ControlCanvasInfoSnapshot(
            workspaceID: ws.id,
            mode: ws.layoutMode.rawValue,
            panes: panes,
            magnification: magnification,
            centerX: centerX,
            centerY: centerY
        )
    }

    func controlCanvasSetMode(
        routing: ControlRoutingSelectors,
        mode: String
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        switch mode {
        case "toggle":
            ws.toggleCanvasLayout()
        case "canvas":
            ws.setLayoutMode(.canvas)
        case "zoomableSplits", "zoomable-splits", "zoomable_splits", "zoomable":
            ws.setLayoutMode(.zoomableSplits)
        default:
            ws.setLayoutMode(.splits)
        }
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasSetFrame(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        frame: ControlCanvasFrame
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        guard ws.canvasModel.frame(of: surfaceID) != nil else {
            return .paneNotFound(surfaceID)
        }
        ws.canvasModel.setFrame(
            CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            for: surfaceID
        )
        ws.canvasModel.viewport?.modelDidChangeExternally(animated: true)
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasAlign(
        routing: ControlRoutingSelectors,
        command: ControlCanvasAlignCommand
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        CanvasActionExecutor(workspace: ws).perform(.alignment(command.alignmentCommand))
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasReveal(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard let viewport = activeViewport(for: ws) else { return .notCanvasMode }
        guard let target = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedPane
        }
        guard viewportContainsPane(target, in: ws) else {
            return .paneNotFound(target)
        }
        viewport.revealPane(target, animated: true)
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard let viewport = activeViewport(for: ws) else { return .notCanvasMode }
        viewport.toggleOverview()
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: ControlCanvasZoomDirection
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard activeViewport(for: ws) != nil else { return .notCanvasMode }
        let executor = CanvasActionExecutor(workspace: ws)
        switch direction {
        case .zoomIn:
            executor.perform(.zoomIn)
        case .zoomOut:
            executor.perform(.zoomOut)
        case .reset:
            executor.perform(.zoomReset)
        }
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasJoin(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        targetSurfaceID: UUID
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        guard ws.canvasModel.frame(of: surfaceID) != nil else { return .paneNotFound(surfaceID) }
        guard ws.canvasModel.frame(of: targetSurfaceID) != nil else { return .paneNotFound(targetSurfaceID) }
        if ws.canvasModel.joinPanel(surfaceID, withPaneContaining: targetSurfaceID) {
            ws.canvasModel.viewport?.modelDidChangeExternally(animated: true)
            ws.focusPanel(surfaceID)
        }
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasBreak(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        guard ws.canvasModel.frame(of: surfaceID) != nil else { return .paneNotFound(surfaceID) }
        if ws.canvasModel.breakOutPanel(surfaceID) {
            ws.canvasModel.viewport?.modelDidChangeExternally(animated: true)
            ws.focusPanel(surfaceID)
            ws.canvasModel.viewport?.revealPane(surfaceID, animated: true)
        }
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasSelectTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        guard ws.canvasModel.frame(of: surfaceID) != nil else { return .paneNotFound(surfaceID) }
        // focusPanel selects the tab in canvas mode and moves keyboard focus.
        ws.focusPanel(surfaceID)
        ws.canvasModel.viewport?.modelDidChangeExternally(animated: false)
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasSetViewport(
        routing: ControlRoutingSelectors,
        centerX: Double,
        centerY: Double,
        magnification: Double?
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard let viewport = activeViewport(for: ws) else { return .notCanvasMode }
        viewport.setViewport(
            center: CGPoint(x: centerX, y: centerY),
            magnification: magnification.map { CGFloat($0) }
        )
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasNewPane(
        routing: ControlRoutingSelectors,
        type: String
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notFreeformCanvasMode }
        let paneType: CanvasNewPaneType = (type == "browser") ? .browser : .terminal
        guard let surfaceID = ws.openNewCanvasPane(type: paneType, focus: true) else {
            return .tabManagerUnavailable
        }
        return .created(mode: ws.layoutMode.rawValue, surfaceID: surfaceID)
    }
}

private extension TerminalController {
    func activeViewport(for workspace: Workspace) -> (any CanvasViewportControlling)? {
        switch workspace.layoutMode {
        case .canvas:
            workspace.canvasModel.viewport
        case .zoomableSplits:
            workspace.zoomableSplitViewport
        case .splits:
            nil
        }
    }

    func viewportContainsPane(_ panelId: UUID, in workspace: Workspace) -> Bool {
        switch workspace.layoutMode {
        case .canvas:
            workspace.canvasModel.frame(of: panelId) != nil
        case .zoomableSplits:
            workspace.paneId(forPanelId: panelId) != nil
        case .splits:
            false
        }
    }
}

extension ControlCanvasAlignCommand {
    /// Maps the wire command onto the canvas engine's alignment command.
    var alignmentCommand: CanvasAlignmentCommand {
        switch self {
        case .tidy: return .tidy
        case .alignLeft: return .alignLeft
        case .alignRight: return .alignRight
        case .alignTop: return .alignTop
        case .alignBottom: return .alignBottom
        case .equalizeWidths: return .equalizeWidths
        case .equalizeHeights: return .equalizeHeights
        case .distributeHorizontally: return .distributeHorizontally
        case .distributeVertically: return .distributeVertically
        }
    }
}
