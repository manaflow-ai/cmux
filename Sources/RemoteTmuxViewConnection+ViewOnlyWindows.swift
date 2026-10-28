import Foundation

extension RemoteTmuxViewConnection {
    /// Links each window that exists only in the view into the real session it was created next
    /// to, right after its neighbour there (`link-window -a`), so it becomes a tab of that
    /// workspace. The window stays linked into the view too, as every mirrored window is. The
    /// reconcile that follows picks it up as a mirrored window.
    ///
    /// Returns the windows it linked. They are cmux's from now on, marked like any window cmux
    /// links, so if their new session is killed later they are cleaned up instead of adopted again.
    func adoptViewOnlyWindows(
        _ adoptions: [RemoteTmuxViewOnlyWindows.Adoption],
        over conn: RemoteTmuxControlConnection
    ) -> [String] {
        var adopted: [String] = []
        for (adoption, command) in zip(adoptions, RemoteTmuxViewOnlyWindows.linkCommands(adoptions))
        where conn.send(command) {
            _ = conn.send(RemoteTmuxViewSession.linkedMarkCommand(windowId: adoption.windowId))
            adopted.append(adoption.windowId)
        }
        if !adopted.isEmpty { requestReconcile() }
        return adopted
    }
}
