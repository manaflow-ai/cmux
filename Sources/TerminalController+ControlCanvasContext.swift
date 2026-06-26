import CmuxCanvas
import CmuxCanvasUI
import CmuxControlSocket
import Foundation

/// Canvas-domain witnesses. Reads snapshot the workspace's `canvasModel`;
/// mutations route through `CanvasActionExecutor` / the model so the socket
/// shares one execution path with shortcuts, the palette, and the View menu.
extension TerminalController: ControlCanvasContext {
    /// The routing twin used by every canvas verb: TabManager, then workspace.
    private func resolveCanvasWorkspace(routing: ControlRoutingSelectors) -> Workspace? {
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
        let panes: [ControlCanvasPaneSummary] = ws.canvasModel.layout.panes.map { pane in
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
        var magnification: Double?
        var centerX: Double?
        var centerY: Double?
        if ws.layoutMode.usesCanvasHost, let viewport = ws.canvasModel.viewport {
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
        case "niri":
            ws.setLayoutMode(.niri)
        case "canvas":
            ws.setLayoutMode(.canvas)
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
        guard ws.layoutMode == .canvas else { return .notCanvasMode }
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
        guard ws.layoutMode == .canvas else { return .notCanvasMode }
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
        guard let target = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedPane
        }
        guard ws.canvasModel.frame(of: target) != nil else {
            return .paneNotFound(target)
        }
        ws.canvasModel.viewport?.revealPane(target, animated: true)
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard CanvasActionExecutor(workspace: ws).perform(.toggleOverview) else {
            return .notCanvasMode
        }
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: ControlCanvasZoomDirection
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        let executor = CanvasActionExecutor(workspace: ws)
        let didZoom = switch direction {
        case .zoomIn:
            executor.perform(.zoomIn)
        case .zoomOut:
            executor.perform(.zoomOut)
        case .reset:
            executor.perform(.zoomReset)
        }
        guard didZoom else {
            return .notCanvasMode
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
        ws.canvasModel.viewport?.setViewport(
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
        guard ws.layoutMode.usesCanvasHost else { return .notCanvasMode }
        let paneType: CanvasNewPaneType = (type == "browser") ? .browser : .terminal
        guard let surfaceID = ws.openNewCanvasPane(type: paneType, focus: true) else {
            return .tabManagerUnavailable
        }
        return .created(mode: ws.layoutMode.rawValue, surfaceID: surfaceID)
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
