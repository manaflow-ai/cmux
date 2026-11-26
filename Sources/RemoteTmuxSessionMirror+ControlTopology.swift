import Bonsplit
import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    func controlPaneID(forPane tmuxPaneID: Int) -> PaneID? {
        controlPaneIdByPane[tmuxPaneID]
    }

    func reconcileControlPaneIdentities(livePaneIDs: Set<Int>) {
        let removedPaneIDs = controlPaneIdByPane.keys.filter { !livePaneIDs.contains($0) }
        for tmuxPaneID in removedPaneIDs {
            cleanupControlPaneIdentity(tmuxPaneID: tmuxPaneID)
            controlPaneIdByPane[tmuxPaneID] = nil
        }
        for tmuxPaneID in livePaneIDs where controlPaneIdByPane[tmuxPaneID] == nil {
            controlPaneIdByPane[tmuxPaneID] = PaneID()
        }
    }

    func teardownControlPaneIdentities() {
        for tmuxPaneID in controlPaneIdByPane.keys {
            cleanupControlPaneIdentity(tmuxPaneID: tmuxPaneID)
        }
        controlPaneIdByPane.removeAll()
        controlSurfaceIdByPane.removeAll()
        tmuxPaneIdByControlSurface.removeAll()
    }

    func updateControlSurface(tmuxPaneID: Int, surfaceID: UUID?, windowID: Int?) {
        guard controlPaneIdByPane[tmuxPaneID] != nil else { return }
        if let ownerWindowID = windowIdByPane[tmuxPaneID] {
            guard ownerWindowID == windowID else { return }
        } else if surfaceID != nil {
            return
        }
        let previousSurfaceID = controlSurfaceIdByPane[tmuxPaneID]
        guard previousSurfaceID != surfaceID else { return }
        if let previousSurfaceID {
            tmuxPaneIdByControlSurface[previousSurfaceID] = nil
            onControlSurfaceRemoved(previousSurfaceID)
        }
        controlSurfaceIdByPane[tmuxPaneID] = surfaceID
        if let surfaceID { tmuxPaneIdByControlSurface[surfaceID] = tmuxPaneID }
    }

    func controlPaneLocations(
        containerPanelID requestedContainerPanelID: UUID? = nil
    ) -> [RemoteTmuxControlPaneLocation] {
        guard workspace != nil else { return [] }
        let windowIDs: [Int]
        if let requestedContainerPanelID {
            guard let windowID = windowIdByPanel[requestedContainerPanelID] else { return [] }
            windowIDs = [windowID]
        } else {
            windowIDs = connection.windowOrder
        }
        return windowIDs.flatMap { windowID -> [RemoteTmuxControlPaneLocation] in
            guard let containerPanelID = self.panelIdByWindow[windowID],
                  let windowMirror = self.windowMirrorByWindowId[windowID] else { return [] }
            return windowMirror.controlPanes().compactMap {
                guard self.windowIdByPane[$0.tmuxPaneID] == windowID else { return nil }
                return RemoteTmuxControlPaneLocation(
                    containerPanelID: containerPanelID,
                    owner: self,
                    windowMirror: windowMirror,
                    pane: $0
                )
            }
        }
    }

    /// Resolves one window's active pane without materializing its full control
    /// topology.
    func activeControlPaneLocation(
        containerPanelID: UUID
    ) -> RemoteTmuxControlPaneLocation? {
        guard workspace != nil,
              let active = activePaneProjection(containerPanelID: containerPanelID),
              let paneID = controlPaneIdByPane[active.tmuxPaneID] else { return nil }

        return RemoteTmuxControlPaneLocation(
            containerPanelID: containerPanelID,
            owner: self,
            windowMirror: active.windowMirror,
            pane: RemoteTmuxControlPane(
                tmuxPaneID: active.tmuxPaneID,
                paneID: paneID,
                panel: active.panel,
                title: active.windowMirror.title(forPane: active.tmuxPaneID),
                isFocused: true
            )
        )
    }

    /// Resolves the active pane's input identity without allocating control
    /// metadata such as its formatted title.
    func activeControlSurfaceProjection(
        containerPanelID: UUID
    ) -> (surfaceID: UUID, paneID: UUID?, panel: TerminalPanel)? {
        guard let active = activePaneProjection(containerPanelID: containerPanelID) else {
            return nil
        }
        return (
            active.panel.id,
            controlPaneIdByPane[active.tmuxPaneID]?.id,
            active.panel
        )
    }

    private func activePaneProjection(
        containerPanelID: UUID
    ) -> (tmuxPaneID: Int, panel: TerminalPanel, windowMirror: RemoteTmuxWindowMirror)? {
        guard let windowID = windowIdByPanel[containerPanelID],
              let windowMirror = windowMirrorByWindowId[windowID] else { return nil }

        let tmuxPaneID: Int
        if let mirrorActivePaneID = windowMirror.activePaneId,
           windowIdByPane[mirrorActivePaneID] == windowID {
            tmuxPaneID = mirrorActivePaneID
        } else if let remoteActivePaneID = connection.activePaneByWindow[windowID],
                  windowIdByPane[remoteActivePaneID] == windowID {
            tmuxPaneID = remoteActivePaneID
        } else {
            return nil
        }

        guard let panel = windowMirror.panel(forPane: tmuxPaneID) else { return nil }
        return (tmuxPaneID, panel, windowMirror)
    }

    func controlPaneLocation(paneID: UUID) -> RemoteTmuxControlPaneLocation? {
        controlPaneLocations().first(where: { $0.pane.paneID.id == paneID })
    }

    /// Resolves a projected pane surface through the session-owned reverse index.
    func controlPaneLocation(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        guard let tmuxPaneID = tmuxPaneIdByControlSurface[surfaceID],
              controlSurfaceIdByPane[tmuxPaneID] == surfaceID,
              let windowID = windowIdByPane[tmuxPaneID],
              let containerPanelID = panelIdByWindow[windowID],
              let windowMirror = windowMirrorByWindowId[windowID],
              let pane = windowMirror.controlPane(tmuxPaneID: tmuxPaneID),
              pane.panel.id == surfaceID else {
            return nil
        }
        return RemoteTmuxControlPaneLocation(
            containerPanelID: containerPanelID,
            owner: self,
            windowMirror: windowMirror,
            pane: pane
        )
    }

    func controlFocus(
        pane tmuxPaneID: Int,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID],
              let windowMirror = windowMirrorByWindowId[windowID] else {
            return false
        }
        return windowMirror.requestControlFocus(
            pane: tmuxPaneID,
            sendTracked: { [connection] command, trackedCompletion in
                connection.sendTracked(command, completion: trackedCompletion)
            },
            completion: completion
        )
    }

    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return sendInputBytes(data, toPane: tmuxPaneID)
    }

    func sendKey(
        toPane tmuxPaneID: Int,
        name: String
    ) -> RemoteTmuxControlKeySendResult {
        guard let key = RemoteTmuxKeyName(rawName: name) else { return .unknownKey }
        return sendNamedKey(key, toPane: tmuxPaneID) ? .sent : .rejected
    }

    func requestSplit(
        fromPane tmuxPaneID: Int,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent,
        insertBefore: Bool,
        shellCommand: String?,
        workingDirectory: String?
    ) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID] else { return false }
        return sendSplit(
            vertical: vertical,
            windowID: windowID,
            paneID: tmuxPaneID,
            focusIntent: focusIntent,
            insertBefore: insertBefore,
            shellCommand: shellCommand,
            workingDirectory: workingDirectory
        )
    }

    /// Routes a split of a mirror window-tab to tmux, targeting its focused
    /// pane (or its only pane). Requires a live stream so callers never report a
    /// mutation that reconnecting tmux could not receive.
    func requestSplit(
        windowPanelId panelId: UUID,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent
    ) -> Bool {
        guard connection.connectionState == .connected,
              let windowID = windowId(forPanel: panelId) else { return false }
        let targetPane = windowMirrorByWindowId[windowID]?.activePaneId
            ?? connection.windowsByID[windowID]?.paneIDsInOrder.first
        guard let targetPane else { return false }
        return sendSplit(
            vertical: vertical,
            windowID: windowID,
            paneID: targetPane,
            focusIntent: focusIntent,
            insertBefore: false,
            shellCommand: nil,
            workingDirectory: nil
        )
    }

    private func sendSplit(
        vertical: Bool,
        windowID: Int,
        paneID: Int,
        focusIntent: RemoteTmuxSplitFocusIntent,
        insertBefore: Bool,
        shellCommand: String?,
        workingDirectory: String?
    ) -> Bool {
        let command: String
        if let shellCommand {
            guard let forkCommand = focusIntent.agentForkCommand(
                vertical: vertical,
                windowID: windowID,
                paneID: paneID,
                insertBefore: insertBefore,
                shellCommand: shellCommand,
                workingDirectory: workingDirectory
            ) else {
                return false
            }
            command = forkCommand
        } else {
            command = focusIntent.command(
                vertical: vertical,
                windowID: windowID,
                paneID: paneID,
                insertBefore: insertBefore
            )
        }
        guard focusIntent == .focusCreatedPane,
              let windowMirror = windowMirrorByWindowId[windowID] else {
            return connection.send(command)
        }
        let requestID = UUID()
        let accepted = connection.sendNewPane(command) { [weak windowMirror] paneID in
            windowMirror?.resolvePendingCreatedPaneFocus(
                requestID: requestID,
                createdPaneID: paneID
            )
        }
        if accepted {
            windowMirror.noteCreatedPaneFocusRequestAccepted(requestID: requestID)
        }
        return accepted
    }

    func requestAgentForkNewWindow(
        afterPane tmuxPaneID: Int,
        shellCommand: String,
        workingDirectory: String?
    ) -> Bool {
        guard connection.connectionState == .connected,
              let afterWindowID = windowIdByPane[tmuxPaneID],
              let command = RemoteTmuxController.agentForkNewWindowCommand(
                afterWindowId: afterWindowID,
                workingDirectory: workingDirectory,
                shellCommand: shellCommand
              ) else {
            return false
        }
        return connection.sendNewWindow(command) { [weak self] windowID in
            guard let windowID else { return }
            self?.focusWindowWhenAvailable(windowID)
        }
    }

    func requestResizePane(_ tmuxPaneID: Int, direction: String, amountCells: Int) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID],
              let windowMirror = windowMirrorByWindowId[windowID] else { return false }
        return windowMirror.requestResizePane(
            tmuxPaneID,
            direction: direction,
            amountCells: amountCells
        )
    }

    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID],
              let windowMirror = windowMirrorByWindowId[windowID] else { return false }
        return windowMirror.requestResizePane(
            tmuxPaneID,
            absoluteAxis: absoluteAxis,
            targetCells: targetCells
        )
    }

    func requestResizePane(
        _ tmuxPaneID: Int,
        absoluteAxis: String,
        targetPercentage: Int
    ) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID],
              let windowMirror = windowMirrorByWindowId[windowID] else { return false }
        return windowMirror.requestResizePane(
            tmuxPaneID,
            absoluteAxis: absoluteAxis,
            targetPercentage: targetPercentage
        )
    }

    func requestRespawnPane(
        _ tmuxPaneID: Int,
        command shellCommand: String,
        workingDirectory: String?
    ) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID],
              RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else { return false }
        var command = "respawn-pane -k -t @\(windowID).%\(tmuxPaneID)"
        if let directory = workingDirectory {
            guard RemoteTmuxHost.controlModeLineSafeName(directory) != nil else { return false }
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        command += " \(RemoteTmuxHost.shellSingleQuoted(shellCommand))"
        return connection.send(command)
    }

    func requestKillPane(_ tmuxPaneID: Int) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID] else { return false }
        return connection.send("kill-pane -t @\(windowID).%\(tmuxPaneID)")
    }

    private func cleanupControlPaneIdentity(tmuxPaneID: Int) {
        guard let paneID = controlPaneIdByPane[tmuxPaneID] else { return }
        let surfaceID = controlSurfaceIdByPane.removeValue(forKey: tmuxPaneID)
        if let surfaceID {
            tmuxPaneIdByControlSurface[surfaceID] = nil
            onControlSurfaceRemoved(surfaceID)
        }
        onControlPaneRemoved(paneID, nil)
    }
}
