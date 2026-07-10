import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    /// Selects a pane only when the control command was accepted. The tmux
    /// publication remains authoritative when the transport is unavailable.
    @discardableResult
    func focus(pane tmuxPaneID: Int) -> Bool {
        guard sendControlCommand("select-pane -t @\(windowId).%\(tmuxPaneID)") else {
            return false
        }
        noteRemoteActivePane(tmuxPaneID)
        return true
    }

    /// Splits the addressed tmux pane. The new pane arrives through the next
    /// authoritative layout publication.
    @discardableResult
    func requestSplit(fromPane tmuxPaneID: Int, vertical: Bool) -> Bool {
        sendControlCommand(
            "split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(tmuxPaneID)"
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
