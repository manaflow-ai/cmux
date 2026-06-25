import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Creates a pane in the app-wide right-sidebar Dock instead of the main
    /// area, splitting the Dock's own Bonsplit tree. Browser-disabled is handled
    /// by `controlPaneCreate` before this is reached.
    func dockPaneCreate(
        tabManager: TabManager,
        panelType: PanelType,
        url: URL?,
        orientation: SplitOrientation,
        insertFirst: Bool,
        initialDividerPosition: CGFloat?,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        guard panelType == .terminal || panelType == .browser else {
            return .dockUnsupportedType(
                typeRawValue: panelType.rawValue,
                message: dockUnsupportedSurfaceTypeMessage()
            )
        }
        guard RightSidebarMode.dock.isAvailable() else {
            return .dockUnavailable(message: dockUnavailableMessage())
        }
        guard let app = AppDelegate.shared else {
            return .workspaceNotFound
        }
        let dock = app.globalDock
        // An explicit source surface must live in the Dock tree; do not silently
        // fall back to another Dock pane (mirrors the workspace `.noSourceSurface`).
        if let requestedSource = inputs.requestedSourceSurfaceID, !dock.containsPanel(requestedSource) {
            return .noSourceSurface
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = (panelType == .browser) ? .browser : .terminal
        if focus {
            revealDockForFocus(tabManager: tabManager)
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
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .createdDock(
            windowID: windowId,
            workspaceID: dock.workspaceId,
            dockPaneID: paneUUID,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }
}
