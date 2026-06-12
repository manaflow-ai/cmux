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
        let panes: [ControlCanvasPaneSummary] = ws.canvasModel.layout.paneIDs.compactMap { paneID in
            guard let frame = ws.canvasModel.frame(of: paneID.rawValue) else { return nil }
            return ControlCanvasPaneSummary(
                surfaceID: paneID.rawValue,
                frame: ControlCanvasFrame(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                ),
                isFocused: paneID.rawValue == focusedPanelId
            )
        }
        return ControlCanvasInfoSnapshot(
            workspaceID: ws.id,
            mode: ws.layoutMode.rawValue,
            panes: panes
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
        guard ws.layoutMode == .canvas else { return .notCanvasMode }
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
        guard ws.layoutMode == .canvas else { return .notCanvasMode }
        ws.canvasModel.viewport?.toggleOverview()
        return .ok(mode: ws.layoutMode.rawValue)
    }

    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: String
    ) -> ControlCanvasActionResolution {
        guard let ws = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard ws.layoutMode == .canvas else { return .notCanvasMode }
        let executor = CanvasActionExecutor(workspace: ws)
        switch direction {
        case "in":
            executor.perform(.zoomIn)
        case "out":
            executor.perform(.zoomOut)
        default:
            executor.perform(.zoomReset)
        }
        return .ok(mode: ws.layoutMode.rawValue)
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
