import Foundation

/// Windows that exist only in the hidden view session, and where each one belongs.
///
/// A command that names a mirrored window only by its id (`tmux new-window -a -t @12`) lands in
/// whichever session holding that window was used last. The view session is used every few seconds,
/// so the new window ends up in the view and nowhere else (measured on tmux 3.7b), and since cmux
/// shows the real sessions' windows, it never becomes a tab. It belongs in the real session of the
/// window it was created next to, after that window.
///
/// Only windows cmux did not link itself are adopted. A window cmux linked whose home session has
/// since been killed is also in the view alone, and it must be cleaned up rather than moved into a
/// neighbouring session, or killing a session would bring its windows back elsewhere.
enum RemoteTmuxViewOnlyWindows {
    /// Link `windowId` into `sessionName` right after the window at `afterWindowIndex` there.
    struct Adoption: Equatable, Sendable {
        let windowId: String
        let sessionName: String
        let afterWindowIndex: Int
    }

    static func adoptions(
        rows: [RemoteTmuxLinkedWorkspaceModel.WindowRow],
        viewSessionName: String,
        excludedSessions: Set<String>,
        placeholderWindowId: String?,
        cmuxOwnedWindowIds: Set<String>
    ) -> [Adoption] {
        // Each mirrored window's home is the smallest real session holding it, the same rule the
        // workspace grouping uses, so the window joins the workspace its neighbour shows in.
        var home: [String: (session: String, index: Int)] = [:]
        for row in rows where !excludedSessions.contains(row.sessionName) {
            if let current = home[row.windowId], current.session <= row.sessionName { continue }
            home[row.windowId] = (row.sessionName, row.windowIndex)
        }
        let viewRows = rows.filter { $0.sessionName == viewSessionName }.sorted { $0.windowIndex < $1.windowIndex }
        var adoptions: [Adoption] = []
        var neighbour: (session: String, index: Int)?
        for row in viewRows {
            if let rowHome = home[row.windowId] {
                neighbour = rowHome
                continue
            }
            guard row.windowId != placeholderWindowId, !cmuxOwnedWindowIds.contains(row.windowId),
                  let neighbour else { continue }
            adoptions.append(Adoption(
                windowId: row.windowId, sessionName: neighbour.session, afterWindowIndex: neighbour.index))
        }
        return adoptions
    }
}
