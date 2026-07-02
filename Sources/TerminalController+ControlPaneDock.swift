import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Creates a pane in the routed window's right-sidebar Dock instead of the
    /// main area, splitting the Dock's own Bonsplit tree. Browser-disabled is
    /// handled by `controlPaneCreate` before this is reached.
    func dockPaneCreate(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType,
        url: URL?,
        orientation: SplitOrientation,
        insertFirst: Bool,
        initialDividerPosition: CGFloat?,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        if let invalid = validateDockPaneCreateRouting(routing: routing, tabManager: tabManager, panelType: panelType) {
            return invalid
        }
        guard let dockOwnerId = windowDockOwnerIdForCreateRouting(routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let dock = AppDelegate.shared?.windowDockForRegisteredOwner(dockOwnerId) else {
            return .workspaceNotFound
        }
        // An explicit source surface must live in the Dock tree; do not silently
        // fall back to another Dock pane (mirrors the workspace `.noSourceSurface`).
        if let requestedSource = inputs.requestedSourceSurfaceID, !dock.containsPanel(requestedSource) {
            return .noSourceSurface
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = (panelType == .browser) ? .browser : .terminal
        if focus {
            focusAndRevealWindowDock(for: dock, fallback: tabManager)
        }
        let newPanelId = dock.newSplit(
            kind: kind,
            orientation: orientation,
            insertFirst: insertFirst,
            sourcePanelId: inputs.requestedSourceSurfaceID,
            url: kind == .browser ? url : nil,
            command: kind == .terminal ? inputs.initialCommand : nil,
            workingDirectory: kind == .terminal ? inputs.workingDirectory : nil,
            environment: inputs.startupEnvironment,
            tmuxStartCommand: kind == .terminal ? inputs.tmuxStartCommand : nil,
            initialDividerPosition: initialDividerPosition,
            focus: focus
        )
        guard let newPanelId else {
            return .createFailed
        }
        let paneUUID = dock.paneId(forPanelId: newPanelId)?.id
        return .createdDock(
            windowID: dock.workspaceId,
            workspaceID: dock.workspaceId,
            dockPaneID: paneUUID,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }
}
