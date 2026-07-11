import Bonsplit
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
        if let previousSurfaceID { onControlSurfaceRemoved(previousSurfaceID) }
        controlSurfaceIdByPane[tmuxPaneID] = surfaceID
    }

    func controlPaneLocations(
        containerPanelID requestedContainerPanelID: UUID? = nil
    ) -> [RemoteTmuxControlPaneLocation] {
        guard let workspace else { return [] }
        let windowIDs: [Int]
        if let requestedContainerPanelID {
            guard let windowID = windowIdByPanel[requestedContainerPanelID] else { return [] }
            windowIDs = [windowID]
        } else {
            windowIDs = connection.windowOrder
        }
        return windowIDs.flatMap { windowID -> [RemoteTmuxControlPaneLocation] in
            guard let containerPanelID = self.panelIdByWindow[windowID],
                  let window = self.connection.windowsByID[windowID] else { return [] }
            let windowMirror = self.windowMirrorByWindowId[windowID]
            if let windowMirror {
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
            guard let tmuxPaneID = window.paneIDsInOrder.first,
                  self.windowIdByPane[tmuxPaneID] == windowID,
                  let paneID = self.controlPaneIdByPane[tmuxPaneID],
                  let panelID = self.panelIdByPane[tmuxPaneID],
                  let panel = workspace.panels[panelID] as? TerminalPanel else { return [] }
            let pane = RemoteTmuxControlPane(
                tmuxPaneID: tmuxPaneID,
                paneID: paneID,
                panel: panel,
                title: workspace.panelTitle(panelId: panelID) ?? panel.displayTitle,
                isFocused: true
            )
            return [RemoteTmuxControlPaneLocation(
                containerPanelID: containerPanelID,
                owner: self,
                windowMirror: nil,
                pane: pane
            )]
        }
    }

    func controlPaneLocation(paneID: UUID) -> RemoteTmuxControlPaneLocation? {
        controlPaneLocations().first(where: { $0.pane.paneID.id == paneID })
    }

    func controlPaneLocation(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        controlPaneLocations().first(where: { $0.pane.panel.id == surfaceID })
    }

    func controlFocus(pane tmuxPaneID: Int) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID] else { return false }
        return connection.send("select-pane -t @\(windowID).%\(tmuxPaneID)")
    }

    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool {
        guard controlPaneIdByPane[tmuxPaneID] != nil,
              let data = text.data(using: .utf8) else { return false }
        return connection.sendKeys(paneId: tmuxPaneID, data: data)
    }

    func sendKey(
        toPane tmuxPaneID: Int,
        name: String
    ) -> RemoteTmuxControlKeySendResult {
        guard controlPaneIdByPane[tmuxPaneID] != nil else { return .rejected }
        guard let key = RemoteTmuxWindowMirror.tmuxKeyName(name) else { return .unknownKey }
        return connection.send("send-keys -t %\(tmuxPaneID) \(key)") ? .sent : .rejected
    }

    func requestSplit(fromPane tmuxPaneID: Int, vertical: Bool) -> Bool {
        guard let windowID = windowIdByPane[tmuxPaneID] else { return false }
        return connection.send(
            "split-window \(vertical ? "-v" : "-h") -t @\(windowID).%\(tmuxPaneID)"
        )
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
        onControlPaneRemoved(paneID, surfaceID)
    }
}
