import Foundation

extension RemoteTmuxViewConnection {
    /// Links each window that exists only in the view into the real session it was created next
    /// to, right after its neighbour there (`link-window -a`), so it becomes a tab of that
    /// workspace. The window stays linked into the view too, as every mirrored window is.
    ///
    /// Each link and its mark go out as one tracked write, and `onLinked` gets the window when
    /// tmux answers `%end`. From then on the window is cmux's: if its new session is killed
    /// later it is cleaned up instead of adopted again. A link tmux refuses leaves the window
    /// unmarked and unowned, so no reconcile destroys it with `unlink-window -k`.
    nonisolated static func adopt(
        _ adoptions: [RemoteTmuxViewOnlyWindows.Adoption],
        send: (String, @escaping (Bool) -> Void) -> Bool,
        onLinked: @escaping (String) -> Void
    ) {
        for (adoption, command) in zip(adoptions, RemoteTmuxViewOnlyWindows.linkCommands(adoptions)) {
            _ = send(command) { linked in
                if linked { onLinked(adoption.windowId) }
            }
        }
    }

    /// ``adopt(_:send:onLinked:)`` on the view's control stream.
    static func adopt(
        _ adoptions: [RemoteTmuxViewOnlyWindows.Adoption],
        on connection: RemoteTmuxControlConnection,
        onLinked: @escaping (String) -> Void
    ) {
        adopt(adoptions, send: { connection.sendTracked($0, completion: $1) }, onLinked: onLinked)
    }
}
