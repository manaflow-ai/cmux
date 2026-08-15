import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    struct PendingControlPaneFocusRequest {
        let requestID: UUID
        let paneID: Int
        let previousPaneID: Int?
        var completions: [(Bool) -> Void]
    }

    /// Applies one pane-selection mutation optimistically so keyboard routing
    /// follows the requested projected pane immediately. The request remains
    /// pending until tmux publishes that pane as authoritative; a rejected
    /// command rolls the mirror back to its previous live pane.
    func requestControlFocus(
        pane tmuxPaneID: Int,
        sendTracked: (
            _ command: String,
            _ completion: @escaping (Bool) -> Void
        ) -> Bool,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isTornDown, panelsByPaneId[tmuxPaneID] != nil else { return false }
        if pendingControlPaneFocusRequest?.paneID == tmuxPaneID {
            pendingControlPaneFocusRequest?.completions.append(completion)
            return true
        }
        cancelPendingControlPaneFocus()
        let command = "select-pane -t @\(windowId).%\(tmuxPaneID)"
        if activePaneId == tmuxPaneID {
            let accepted = sendTracked(command, completion)
            if !accepted {
                completion(false)
            }
            return accepted
        }

        let requestID = UUID()
        pendingControlPaneFocusRequest = PendingControlPaneFocusRequest(
            requestID: requestID,
            paneID: tmuxPaneID,
            previousPaneID: activePaneId,
            completions: [completion]
        )
        projectActivePane(tmuxPaneID)

        let accepted = sendTracked(command) { [weak self] succeeded in
            guard !succeeded else { return }
            self?.rejectPendingControlPaneFocus(requestID: requestID)
        }
        if !accepted {
            rejectPendingControlPaneFocus(requestID: requestID)
        }
        return accepted
    }

    func resolvePendingControlPaneFocus(authoritativePaneID: Int) {
        guard let request = pendingControlPaneFocusRequest,
              request.paneID == authoritativePaneID else { return }
        pendingControlPaneFocusRequest = nil
        request.completions.forEach { $0(true) }
    }

    func cancelPendingControlPaneFocus(competingPaneID: Int) {
        guard pendingControlPaneFocusRequest?.paneID != competingPaneID else { return }
        cancelPendingControlPaneFocus()
    }

    func cancelPendingControlPaneFocus() {
        guard let request = pendingControlPaneFocusRequest else { return }
        pendingControlPaneFocusRequest = nil
        rollbackPendingControlPaneFocus(request)
        request.completions.forEach { $0(false) }
    }

    private func rejectPendingControlPaneFocus(requestID: UUID) {
        guard let request = pendingControlPaneFocusRequest,
              request.requestID == requestID else { return }
        pendingControlPaneFocusRequest = nil
        rollbackPendingControlPaneFocus(request)
        request.completions.forEach { $0(false) }
    }

    private func rollbackPendingControlPaneFocus(
        _ request: PendingControlPaneFocusRequest
    ) {
        let shouldRestoreFirstResponder =
            panelsByPaneId[request.paneID]?.hostedView.isSurfaceViewFirstResponder() == true
        guard activePaneId == request.paneID,
              let previousPaneID = request.previousPaneID,
              let previousPanel = panelsByPaneId[previousPaneID] else { return }
        projectActivePane(previousPaneID)
        if shouldRestoreFirstResponder {
            previousPanel.hostedView.moveFocus()
        }
    }

    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return connectionSendKeys(paneID: tmuxPaneID, data: data)
    }

    func sendKey(toPane tmuxPaneID: Int, name: String) -> RemoteTmuxControlKeySendResult {
        guard let key = RemoteTmuxKeyName(rawName: name) else { return .unknownKey }
        guard let connection else { return .rejected }
        return connection.sendKey(paneId: tmuxPaneID, key: key) ? .sent : .rejected
    }

    /// Requests pane selection. The next tmux publication remains authoritative
    /// even after the writer accepts this command. Distinct from the UI's
    /// fire-and-forget `focus(pane:)`.
    @discardableResult
    func controlFocus(
        pane tmuxPaneID: Int,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let connection else { return false }
        return requestControlFocus(
            pane: tmuxPaneID,
            sendTracked: { command, trackedCompletion in
                connection.sendTracked(command, completion: trackedCompletion)
            },
            completion: completion
        )
    }

    /// Splits the addressed tmux pane. The new pane arrives through the next
    /// authoritative layout publication.
    @discardableResult
    func requestSplit(
        fromPane tmuxPaneID: Int,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent,
        insertBefore: Bool,
        shellCommand: String?,
        workingDirectory: String?
    ) -> Bool {
        let command: String
        if let shellCommand {
            guard let forkCommand = focusIntent.agentForkCommand(
                vertical: vertical,
                windowID: windowId,
                paneID: tmuxPaneID,
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
                windowID: windowId,
                paneID: tmuxPaneID,
                insertBefore: insertBefore
            )
        }
        guard focusIntent == .focusCreatedPane else {
            return sendControlCommand(command)
        }
        guard let connection else { return false }
        let requestID = UUID()
        let accepted = connection.sendNewPane(command) { [weak self] paneID in
            self?.resolvePendingCreatedPaneFocus(
                requestID: requestID,
                createdPaneID: paneID
            )
        }
        if accepted {
            noteCreatedPaneFocusRequestAccepted(requestID: requestID)
        }
        return accepted
    }

    /// Resizes the addressed tmux pane by `amountCells` relative to one of its
    /// borders. Tmux's next layout publication remains the sole source of applied
    /// geometry.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, direction: String, amountCells: Int) -> Bool {
        guard amountCells > 0 else { return false }
        let flag: String
        switch direction {
        case "left": flag = "-L"
        case "right": flag = "-R"
        case "up": flag = "-U"
        case "down": flag = "-D"
        default: return false
        }
        return sendControlCommand(
            "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(amountCells)"
        )
    }

    /// The `resize-pane` line for an absolute width/height in cells, shared
    /// by the fire-and-forget CLI path and the tracked divider send.
    func resizePaneCommand(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> String? {
        guard targetCells > 0 else { return nil }
        let flag: String
        switch absoluteAxis {
        case "horizontal": flag = "-x"
        case "vertical": flag = "-y"
        default: return nil
        }
        return "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(targetCells)"
    }

    /// Sets the addressed tmux pane's width or height in terminal cells. This
    /// is shared by CLI absolute resizing and native divider propagation.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> Bool {
        guard let command = resizePaneCommand(
            tmuxPaneID, absoluteAxis: absoluteAxis, targetCells: targetCells
        ) else { return false }
        return sendControlCommand(command)
    }

    /// Sets the addressed tmux pane's width or height as a percentage of the
    /// tmux window, preserving native `resize-pane -x/-y N%` semantics.
    @discardableResult
    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetPercentage: Int) -> Bool {
        guard targetPercentage > 0 else { return false }
        let flag: String
        switch absoluteAxis {
        case "horizontal": flag = "-x"
        case "vertical": flag = "-y"
        default: return false
        }
        return sendControlCommand(
            "resize-pane -t @\(windowId).%\(tmuxPaneID) \(flag) \(targetPercentage)%"
        )
    }

    /// Respawns the addressed tmux pane without replacing its projected IDs.
    @discardableResult
    func requestRespawnPane(
        _ tmuxPaneID: Int,
        command shellCommand: String,
        workingDirectory: String?
    ) -> Bool {
        guard RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else {
            return false
        }
        var command = "respawn-pane -k -t @\(windowId).%\(tmuxPaneID)"
        if let directory = workingDirectory {
            guard RemoteTmuxHost.controlModeLineSafeName(directory) != nil else { return false }
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        command += " \(RemoteTmuxHost.shellSingleQuoted(shellCommand))"
        return sendControlCommand(command)
    }

    /// Kills the addressed tmux pane. Removal arrives through the next layout
    /// publication (or window-close event for the last pane).
    @discardableResult
    func requestKillPane(_ tmuxPaneID: Int) -> Bool {
        sendControlCommand("kill-pane -t @\(windowId).%\(tmuxPaneID)")
    }
}
