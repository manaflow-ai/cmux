import CmuxRemoteSession
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
        _ location: RemoteTmuxControlPaneLocation,
        workspace: Workspace,
        tabManager: TabManager
    ) -> Bool {
        guard location.controlFocus() else { return false }
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
        guard remote.sendInput(text) else {
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
        switch remote.sendKey(key) {
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
        let location: RemoteTmuxControlPaneLocation
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
        guard location.requestSplit(vertical: direction.orientation == .vertical) else {
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
        let location: RemoteTmuxControlPaneLocation
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
        guard location.requestRespawn(
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
        let location: RemoteTmuxControlPaneLocation
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
        guard location.requestKill() else {
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
        let location: RemoteTmuxControlPaneLocation
        if let paneID = inputs.paneID {
            guard let remote = workspace.remoteTmuxControlPane(paneID: paneID) else { return nil }
            location = remote
        } else if let focusedPanelID = workspace.focusedPanelId,
                  workspace.isRemoteTmuxControlContainer(focusedPanelID) {
            guard let focused = workspace.activeRemoteTmuxControlPane(
                containerPanelID: focusedPanelID
            ) else { return .noFocusedPane }
            location = focused
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
        switch inputs.intent {
        case .tmuxAbsoluteCells(let axis, let targetCells, let fallbackPoints):
            guard location.requestResizePane(
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
                targetPixels: fallbackPoints
            )

        case .tmuxAbsolutePercentage(let axis, let percentage, let fallbackPoints):
            guard location.requestResizePane(
                location.pane.tmuxPaneID,
                absoluteAxis: axis,
                targetPercentage: percentage
            ) else {
                return unavailable
            }
            return .remoteAbsoluteResizeRequested(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: paneID,
                absoluteAxis: axis,
                targetPixels: fallbackPoints
            )

        case .tmuxRelative(let direction, let amountCells, let fallbackPoints):
            guard location.requestResizePane(
                location.pane.tmuxPaneID,
                direction: direction,
                amountCells: amountCells
            ) else {
                return unavailable
            }
            return .remoteRelativeResizeRequested(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: paneID,
                direction: direction,
                amount: fallbackPoints
            )

        case .outerAbsolute(let axis, let targetPoints):
            guard targetPoints.isFinite else { return unavailable }
            guard let windowMirror = location.windowMirror else { return unavailable }
            let orientation: RemoteTmuxSplitOrientation
            switch axis {
            case "horizontal": orientation = .horizontal
            case "vertical": orientation = .vertical
            default: return unavailable
            }
            guard let context = RemoteTmuxNativeSplitTree(layout: windowMirror.layout)
                .paneResizeContext(
                    paneID: location.pane.tmuxPaneID,
                    orientation: orientation
                ), let metrics = windowMirror.nativeLayoutMetrics() else {
                return unavailable
            }
            guard context.hasSplitAncestor else {
                return .noAbsoluteSplitAncestor(paneID: paneID, absoluteAxis: axis)
            }
            let targetCells = metrics.requestedTmuxSpan(
                pane: context.pane,
                orientation: orientation,
                outerExtent: CGFloat(targetPoints)
            )
            guard location.requestResizePane(
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
                targetPixels: targetPoints
            )

        case .borderRelative(let directionRaw, let amountPoints):
            guard let windowMirror = location.windowMirror,
                  let direction = V2PaneResizeDirection(rawValue: directionRaw),
                  let metrics = windowMirror.nativeLayoutMetrics() else {
                return unavailable
            }
            let orientation: RemoteTmuxSplitOrientation = direction.splitOrientation == "horizontal"
                ? .horizontal
                : .vertical
            guard let context = RemoteTmuxNativeSplitTree(layout: windowMirror.layout)
                .paneResizeContext(
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
            let commandPaneID: Int
            if direction.requiresPaneInFirstChild {
                guard let target = context.trailingResizeTargetPaneID else {
                    return unavailable
                }
                commandPaneID = target
            } else {
                guard let target = context.leadingResizeTargetPaneID else {
                    return unavailable
                }
                commandPaneID = target
            }
            let amountCells = metrics.requestedTmuxCellDelta(
                pointDelta: CGFloat(amountPoints),
                orientation: orientation
            )
            guard location.requestResizePane(
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
                amount: amountPoints
            )
        }
    }
}
