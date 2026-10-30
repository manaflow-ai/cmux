import CmuxControlSocket
import Foundation

/// The `surface.textbox.*` witness: resolves a terminal surface the same way
/// `surface.clear_history` does (Dock first, then the routed workspace) and
/// applies the requested TextBox Input action.
extension TerminalController {
    func controlSurfaceTextBox(
        action: ControlSurfaceTextBoxAction,
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        focusRequested: Bool
    ) -> ControlSurfaceTextBoxResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let focus = v2FocusAllowed(requested: focusRequested)
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let panel = target.terminalPanel else {
                return .surfaceNotTerminal(surfaceId)
            }
            let shouldFocus = focus && (action == .show || (action == .toggle && !panel.isTextBoxActive))
            if shouldFocus {
                guard focusAndRevealWindowDock(for: dock, fallback: tabManager) else {
                    return .dockUnavailable(message: dockFocusUnavailableMessage())
                }
                dock.focusPanelFromDockInteraction(surfaceId, window: nil)
            }
            // Dock selection reasserts terminal focus; apply the TextBox intent
            // afterwards so it remains the final responder target.
            return applied(
                action,
                to: panel,
                focus: focus,
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        // A present-but-unresolvable surface_id must never fall back to the
        // focused surface: that would toggle a TextBox the caller did not name.
        if hasSurfaceIDParam, surfaceID == nil {
            return .surfaceNotFoundForID
        }
        let target: (surfaceID: UUID, panel: TerminalPanel)?
        if let surfaceID {
            target = ws.controlTerminalTarget(for: surfaceID)
        } else {
            target = ws.controlDefaultTerminalTarget(paneID: routing.paneID)
        }
        guard let target else {
            if let surfaceID {
                return ws.panels[surfaceID] == nil ? .surfaceNotFoundForID : .surfaceNotTerminal(surfaceID)
            }
            return .noFocusedSurface
        }
        let shouldFocus = focus && (action == .show || (action == .toggle && !target.panel.isTextBoxActive))
        if shouldFocus, let remote = ws.remoteTmuxControlPane(surfaceID: target.surfaceID) {
            guard focusRemoteTmuxControlPane(remote, workspace: ws, tabManager: tabManager) else {
                return .surfaceNotFoundForID
            }
        }
        let resolution = applied(
            action,
            to: target.panel,
            focus: focus,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: target.surfaceID
        )
        // A granted --focus reveals the terminal like surface.focus, so the
        // TextBox takes focus now instead of whenever its workspace is next
        // shown.
        if focus, target.panel.isTextBoxActive, ws.panels[target.surfaceID] != nil {
            v2MaybeFocusWindow(for: tabManager)
            tabManager.focusTab(
                ws.id,
                surfaceId: target.surfaceID,
                suppressFlash: true,
                focusIntent: .terminal(.textBoxInput)
            )
        }
        return resolution
    }

    private func applied(
        _ action: ControlSurfaceTextBoxAction,
        to panel: TerminalPanel,
        focus: Bool,
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> ControlSurfaceTextBoxResolution {
        let changed: Bool
        switch action {
        case .toggle:
            changed = panel.setTextBoxInputVisible(!panel.isTextBoxActive, focus: focus)
        case .show:
            changed = panel.setTextBoxInputVisible(true, focus: focus)
        case .hide:
            changed = panel.setTextBoxInputVisible(false, focus: false)
        case .state:
            changed = false
        }
        return .applied(
            windowID: windowID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            visible: panel.isTextBoxActive,
            changed: changed
        )
    }
}
