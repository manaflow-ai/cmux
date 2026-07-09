import Foundation

enum RemoteTmuxSessionEndAction: Equatable {
    /// Close only the dead session's workspace.
    case closeWorkspace

    /// Close the dedicated remote-tmux window wholesale because its last session
    /// disconnected and closing only the workspace cannot remove a window's last
    /// workspace.
    case closeDedicatedWindow(UUID)

    /// Decides how a remote session-end is reflected: close just the dead
    /// workspace, or the whole dedicated window when it lost its last session.
    ///
    /// - Parameters:
    ///   - dedicatedWindowId: the host's dedicated mirror window, or `nil` if the
    ///     host still has other live sessions / was mirrored into a shared window.
    ///   - dedicatedWindowOwnedByEndingHost: `true` only if every workspace in that
    ///     window belongs to the ending host (else a moved-in local/other-host
    ///     workspace would be discarded, so only the dead workspace closes).
    ///   - otherMainWindowCount: OTHER open main windows; the dedicated window
    ///     closes only when ≥1 remains, so a disconnect never leaves zero windows.
    /// - Returns: the action to apply.
    static func resolve(
        dedicatedWindowId: UUID?,
        dedicatedWindowOwnedByEndingHost: Bool,
        otherMainWindowCount: Int
    ) -> RemoteTmuxSessionEndAction {
        if let dedicatedWindowId, dedicatedWindowOwnedByEndingHost, otherMainWindowCount >= 1 {
            return .closeDedicatedWindow(dedicatedWindowId)
        }
        return .closeWorkspace
    }
}
