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
        guard location.mirror.controlFocus(pane: location.pane.tmuxPaneID) else { return false }
        if let windowID = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        // The wrapper is the mirror's real Bonsplit tab. Selecting it makes the
        // projected TerminalPanelView visible; mirror.activePaneId drives which
        // inner hosted view receives its `isFocused` responder state.
        workspace.focusPanel(location.containerPanelID)
        return true
    }

    func controlRemoteTmuxSendText(
        workspace: Workspace,
        tabManager: TabManager,
        surfaceID: UUID,
        text: String
    ) -> ControlSurfaceSendResolution? {
        guard let remote = workspace.remoteTmuxControlPane(surfaceID: surfaceID) else { return nil }
        guard remote.mirror.sendInput(toPane: remote.pane.tmuxPaneID, text: text) else {
            return .surfaceUnavailable(surfaceID)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            queued: false
        )
    }

    func controlRemoteTmuxSendKey(
        workspace: Workspace,
        tabManager: TabManager,
        surfaceID: UUID,
        key: String
    ) -> ControlSurfaceSendResolution? {
        guard let remote = workspace.remoteTmuxControlPane(surfaceID: surfaceID) else { return nil }
        switch remote.mirror.sendKey(toPane: remote.pane.tmuxPaneID, name: key) {
        case .sent:
            return .sent(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                queued: false
            )
        case .rejected:
            return .surfaceUnavailable(surfaceID)
        case .unknownKey:
            return .unknownKey
        }
    }

    func controlRemoteTmuxSurfaceSplit(
        workspace: Workspace,
        tabManager: TabManager,
        inputs: ControlSurfaceSplitInputs,
        direction: SplitDirection,
        panelType: PanelType,
        routedPaneID: UUID?
    ) -> ControlSurfaceSplitResolution? {
        guard panelType == .terminal else {
            return nil
        }
        let location: Workspace.RemoteTmuxControlPaneLocation
        if inputs.requestedSourceSurfaceID == nil,
           let routedPaneID,
           let routed = workspace.remoteTmuxControlPane(paneID: routedPaneID) {
            location = routed
        } else {
            guard let targetSurfaceID = inputs.requestedSourceSurfaceID ?? workspace.focusedPanelId else {
                return nil
            }
            switch workspace.remoteTmuxControlSurfaceTarget(surfaceID: targetSurfaceID) {
            case .pane(let resolved):
                location = resolved
            case .unresolvedMirror:
                return inputs.requestedSourceSurfaceID == nil
                    ? .noFocusedSurface
                    : .requestedSurfaceNotFound(targetSurfaceID)
            case .notRemote:
                return nil
            }
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
        inputs: ControlSurfaceRespawnInputs,
        routedPaneID: UUID?
    ) -> ControlSurfaceRespawnResolution? {
        let location: Workspace.RemoteTmuxControlPaneLocation
        if !inputs.hasSurfaceIDParam,
           let routedPaneID,
           let routed = workspace.remoteTmuxControlPane(paneID: routedPaneID) {
            location = routed
        } else {
            guard let requestedSurfaceID = inputs.hasSurfaceIDParam
                ? inputs.requestedSurfaceID
                : workspace.focusedPanelId else {
                return nil
            }
            switch workspace.remoteTmuxControlSurfaceTarget(surfaceID: requestedSurfaceID) {
            case .pane(let resolved):
                location = resolved
            case .unresolvedMirror:
                return inputs.hasSurfaceIDParam
                    ? .surfaceNotFoundForID(requestedSurfaceID)
                    : .noFocusedSurface
            case .notRemote:
                return nil
            }
        }
        let targetSurfaceID = location.pane.panel.id
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
        isImplicitTarget: Bool,
        routedPaneID: UUID?
    ) -> ControlSurfaceCloseResolution? {
        let location: Workspace.RemoteTmuxControlPaneLocation
        if isImplicitTarget,
           let routedPaneID,
           let routed = workspace.remoteTmuxControlPane(paneID: routedPaneID) {
            location = routed
        } else {
            switch workspace.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
            case .pane(let resolved):
                location = resolved
            case .unresolvedMirror:
                return isImplicitTarget ? .noFocusedSurface : .surfaceNotFound(surfaceID)
            case .notRemote:
                return nil
            }
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

    /// Routes `pane.resize` to a projected mirror pane when the explicit or
    /// focused target belongs to remote tmux. A `nil` result means the target is
    /// owned by the workspace's ordinary Bonsplit tree.
    func controlRemoteTmuxPaneResize(
        workspace: Workspace,
        tabManager: TabManager,
        inputs: ControlPaneResizeInputs
    ) -> ControlPaneResizeResolution? {
        let location: Workspace.RemoteTmuxControlPaneLocation
        if let paneID = inputs.paneID {
            guard let remote = workspace.remoteTmuxControlPane(paneID: paneID) else { return nil }
            location = remote
        } else if let focusedPanelID = workspace.focusedPanelId,
                  let mirror = workspace.remoteTmuxWindowMirror(forPanelId: focusedPanelID) {
            guard let pane = mirror.activeControlPane() else { return .noFocusedPane }
            location = (focusedPanelID, mirror, pane)
        } else {
            return nil
        }

        let paneID = location.pane.paneID.id
        let unavailable = ControlPaneResizeResolution.remoteResizeUnavailable(
            paneID: paneID,
            message: String(
                localized: "socket.pane.resize.remoteUnavailable",
                defaultValue: "The remote tmux pane is not ready to resize; wait for it to become available and retry."
            )
        )
        guard let metrics = location.mirror.nativeLayoutMetrics() else {
            return unavailable
        }
        let splitTree = RemoteTmuxNativeSplitTree(layout: location.mirror.layout)
        if let axis = inputs.absoluteAxis, let targetPixels = inputs.targetPixels {
            guard targetPixels.isFinite else {
                return unavailable
            }
            let orientation: SplitOrientation = axis == "horizontal" ? .horizontal : .vertical
            guard let context = splitTree.paneResizeContext(
                paneID: location.pane.tmuxPaneID,
                orientation: orientation
            ) else {
                return unavailable
            }
            guard context.hasSplitAncestor else {
                return .noAbsoluteSplitAncestor(paneID: paneID, absoluteAxis: axis)
            }
            let targetCells = inputs.targetCells ?? metrics.requestedTmuxSpan(
                pane: context.pane,
                orientation: orientation,
                outerExtent: CGFloat(targetPixels)
            )
            guard location.mirror.requestResizePane(
                location.pane.tmuxPaneID,
                absoluteAxis: axis,
                targetCells: targetCells
            ) else {
                return unavailable
            }
            return .remoteAbsoluteResizeRequested(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: paneID,
                absoluteAxis: axis,
                targetPixels: targetPixels
            )
        }

        guard let directionRaw = inputs.direction,
              let direction = V2PaneResizeDirection(rawValue: directionRaw) else {
            return unavailable
        }
        let orientation: SplitOrientation = direction.splitOrientation == "horizontal"
            ? .horizontal
            : .vertical
        guard let context = splitTree.paneResizeContext(
            paneID: location.pane.tmuxPaneID,
            orientation: orientation
        ) else {
            return unavailable
        }
        guard context.hasSplitAncestor else {
            return .noOrientationSplitAncestor(
                paneID: paneID,
                orientation: direction.splitOrientation,
                direction: directionRaw
            )
        }
        let hasRequestedBorder = direction.requiresPaneInFirstChild
            ? context.hasTrailingBorder
            : context.hasLeadingBorder
        guard hasRequestedBorder else {
            return .noAdjacentBorder(paneID: paneID, direction: directionRaw)
        }
        let amountCells = inputs.amountCells ?? metrics.requestedTmuxCellDelta(
            pointDelta: CGFloat(inputs.amount),
            orientation: orientation
        )
        let commandPaneID: Int
        if direction.requiresPaneInFirstChild {
            commandPaneID = location.pane.tmuxPaneID
        } else if let leadingTarget = context.leadingResizeTargetPaneID {
            commandPaneID = leadingTarget
        } else {
            return .noAdjacentBorder(paneID: paneID, direction: directionRaw)
        }
        guard location.mirror.requestResizePane(
            commandPaneID,
            direction: directionRaw,
            amountCells: amountCells
        ) else {
            return unavailable
        }
        return .remoteRelativeResizeRequested(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            paneID: paneID,
            direction: directionRaw,
            amount: inputs.amount
        )
    }
}
