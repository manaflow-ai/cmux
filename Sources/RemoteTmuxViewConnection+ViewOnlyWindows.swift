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
        Self.adopt(adoptions, send: { command, completion in
            conn.send(command)
        }, onLinked: { adopted.append($0) })
        if !adopted.isEmpty { requestReconcile() }
        return adopted
    }

    /// Sends each adoption's link and calls `onLinked` with its window.
    nonisolated static func adopt(
        _ adoptions: [RemoteTmuxViewOnlyWindows.Adoption],
        send: (String, @escaping (Bool) -> Void) -> Bool,
        onLinked: (String) -> Void
    ) {
        for (adoption, command) in zip(adoptions, RemoteTmuxViewOnlyWindows.linkCommands(adoptions))
        where send(command, { _ in }) && send(RemoteTmuxViewSession.linkedMarkCommand(windowId: adoption.windowId), { _ in }) {
            onLinked(adoption.windowId)
        }
    }
}
