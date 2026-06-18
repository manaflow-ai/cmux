import Foundation

enum RemoteTmuxSessionEndAction: Equatable {
    /// Close only the dead session's workspace.
    case closeWorkspace

    /// Close the dedicated remote-tmux window wholesale because its last session
    /// disconnected and closing only the workspace cannot remove a window's last
    /// workspace.
    case closeDedicatedWindow(UUID)
}
