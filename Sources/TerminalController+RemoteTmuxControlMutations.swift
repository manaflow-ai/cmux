import Bonsplit
import CmuxControlSocket
import CmuxPanes
import Foundation

@MainActor
extension TerminalController {
    /// Pre-mutation validation shared by remote tmux create/split commands.
    func mirrorRoutedUnsupportedOptions(
        insertFirst: Bool = false,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: Double? = nil,
        remotePTYSessionID: String? = nil
    ) -> [String] {
        var unsupported: [String] = []
        if insertFirst { unsupported.append("direction=left/up") }
        if workingDirectory != nil { unsupported.append("working_directory") }
        if initialCommand != nil { unsupported.append("initial_command") }
        if tmuxStartCommand != nil { unsupported.append("tmux_start_command") }
        if !startupEnvironment.isEmpty { unsupported.append("startup_environment") }
        if initialDividerPosition != nil { unsupported.append("initial_divider_position") }
        if remotePTYSessionID != nil { unsupported.append("remote_pty_session_id") }
        return unsupported
    }

    func focusRemoteTmuxControlPane(
        _ location: Workspace.RemoteTmuxControlPaneLocation,
        workspace: Workspace,
        tabManager: TabManager
    ) -> Bool {
        guard location.mirror.focus(pane: location.pane.tmuxPaneID) else { return false }
        if let windowID = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        workspace.focusPanel(location.containerPanelID)
        return true
    }

    func controlRemoteTmuxSurfaceSplit(
        workspace: Workspace,
        tabManager: TabManager,
        inputs: ControlSurfaceSplitInputs,
        direction: SplitDirection,
        panelType: PanelType
    ) -> ControlSurfaceSplitResolution? {
        guard panelType == .terminal,
              let requestedSurfaceID = inputs.requestedSourceSurfaceID,
              let location = workspace.remoteTmuxControlPane(surfaceID: requestedSurfaceID) else {
            return nil
        }
        let unsupported = mirrorRoutedUnsupportedOptions(
            insertFirst: direction.insertFirst,
            workingDirectory: inputs.workingDirectory,
            initialCommand: inputs.initialCommand,
            tmuxStartCommand: inputs.tmuxStartCommand,
            startupEnvironment: inputs.startupEnvironment,
            initialDividerPosition: inputs.initialDividerPosition,
            remotePTYSessionID: inputs.remotePTYSessionID
        ) + inputs.clientUnsupportedRemoteTmuxOptions
        guard unsupported.isEmpty else { return .mirrorUnsupportedOptions(unsupported) }
        guard location.mirror.requestSplit(
            fromPane: location.pane.tmuxPaneID,
            vertical: direction.orientation == .vertical
        ) else {
            return .createFailed
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: workspace)
        return .routedToRemote(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            typeRawValue: panelType.rawValue
        )
    }

    func controlRemoteTmuxSurfaceRespawn(
        workspace: Workspace,
        tabManager: TabManager,
        inputs: ControlSurfaceRespawnInputs
    ) -> ControlSurfaceRespawnResolution? {
        let targetSurfaceID = inputs.hasSurfaceIDParam
            ? inputs.requestedSurfaceID
            : workspace.controlDefaultTerminalTarget(paneID: nil)?.surfaceID
        guard let targetSurfaceID,
              let location = workspace.remoteTmuxControlPane(surfaceID: targetSurfaceID) else {
            return nil
        }
        guard location.mirror.requestRespawnPane(
            location.pane.tmuxPaneID,
            command: inputs.command,
            workingDirectory: inputs.workingDirectory
        ) else {
            return .respawnFailed(targetSurfaceID)
        }
        if inputs.hasFocusParam, v2FocusAllowed(requested: inputs.requestedFocus) {
            _ = focusRemoteTmuxControlPane(location, workspace: workspace, tabManager: tabManager)
        }
        return .respawned(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            surfaceID: targetSurfaceID,
            typeRawValue: location.pane.panel.panelType.rawValue
        )
    }

    func controlRemoteTmuxSurfaceClose(
        workspace: Workspace,
        tabManager: TabManager,
        surfaceID: UUID,
        allowContainerProjection: Bool
    ) -> ControlSurfaceCloseResolution? {
        let location = workspace.remoteTmuxControlPane(surfaceID: surfaceID)
            ?? (allowContainerProjection
                ? workspace.remoteTmuxControlTarget(surfaceID: surfaceID)
                : nil)
        guard let location else {
            return nil
        }
        guard location.mirror.requestKillPane(location.pane.tmuxPaneID) else {
            return .closeFailed(location.pane.panel.id)
        }
        return .closed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            surfaceID: location.pane.panel.id
        )
    }
}
