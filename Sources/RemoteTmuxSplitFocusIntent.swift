import Foundation

/// Selection contract for a remote tmux split. Every mutation caller must state
/// whether tmux may select the created pane; background automation uses
/// `preserveActivePane`, which maps to `split-window -d`.
enum RemoteTmuxSplitFocusIntent: Sendable, Equatable {
    case preserveActivePane
    case focusCreatedPane

    func command(
        vertical: Bool,
        windowID: Int,
        paneID: Int,
        insertBefore: Bool = false
    ) -> String {
        let focusContract = self == .preserveActivePane
            ? "-d"
            : "-P -F '#{pane_id}'"
        let placement = insertBefore ? " -b" : ""
        return "split-window \(focusContract) \(vertical ? "-v" : "-h")\(placement) -t @\(windowID).%\(paneID)"
    }

    func agentForkCommand(
        vertical: Bool,
        windowID: Int,
        paneID: Int,
        insertBefore: Bool,
        shellCommand: String,
        workingDirectory: String?
    ) -> String? {
        guard RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else {
            return nil
        }
        var command = command(
            vertical: vertical,
            windowID: windowID,
            paneID: paneID,
            insertBefore: insertBefore
        )
        if let workingDirectory {
            guard RemoteTmuxHost.controlModeLineSafeName(workingDirectory) != nil else {
                return nil
            }
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(workingDirectory))"
        }
        command += " \(RemoteTmuxHost.shellSingleQuoted(shellCommand))"
        return command
    }
}
