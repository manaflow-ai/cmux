import Foundation

extension RemoteTmuxViewConnection {
    /// Links each window that exists only in the view into the real session it was created next
    /// to, right after its neighbour there (`link-window -a`), so it becomes a tab of that
    /// workspace. The window stays linked into the view too, as every mirrored window is. The
    /// reconcile that follows picks it up as a mirrored window.
    func adoptViewOnlyWindows(_ adoptions: [RemoteTmuxViewOnlyWindows.Adoption], over conn: RemoteTmuxControlConnection) {
        var adopted = false
        for command in RemoteTmuxViewOnlyWindows.linkCommands(adoptions) where conn.send(command) {
            adopted = true
        }
        if adopted { requestReconcile() }
    }
}
