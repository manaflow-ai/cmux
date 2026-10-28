import Foundation

/// Windows that exist only in the hidden view session, and where each one belongs.
///
/// A command that names a mirrored window only by its id (`tmux new-window -a -t @12`) lands in
/// whichever session holding that window was used last. The view session is used every few seconds,
/// so the new window ends up in the view and nowhere else (measured on tmux 3.7b), and since cmux
/// shows the real sessions' windows, it never becomes a tab. It belongs in the real session of the
/// window it was created next to, after that window.
///
/// Only windows cmux did not link itself are adopted, and an adopted window counts as linked by
/// cmux from then on. A window cmux linked whose home session has since been killed is also in the
/// view alone, and it must be cleaned up rather than moved into a neighbouring session, or killing a
/// session would bring its windows back elsewhere.
enum RemoteTmuxViewOnlyWindows {
    /// Link `windowId` into `sessionName` right after `afterWindowId` there.
    ///
    /// The anchor is a window id, not an index, because each `link-window -a` shifts every later
    /// index in the session. Several windows after one mirrored window chain: each one's anchor is
    /// the window adopted just before it, so they keep the order they had in the view.
    struct Adoption: Equatable, Sendable {
        let windowId: String
        let sessionName: String
        let afterWindowId: String
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
        var home: [String: String] = [:]
        for row in rows where !excludedSessions.contains(row.sessionName) {
            if let current = home[row.windowId], current <= row.sessionName { continue }
            home[row.windowId] = row.sessionName
        }
        let viewRows = rows.filter { $0.sessionName == viewSessionName }.sorted { $0.windowIndex < $1.windowIndex }
        var adoptions: [Adoption] = []
        var neighbour: (session: String, windowId: String)?
        for row in viewRows {
            if let rowHome = home[row.windowId] {
                neighbour = (rowHome, row.windowId)
                continue
            }
            guard row.windowId != placeholderWindowId, !cmuxOwnedWindowIds.contains(row.windowId),
                  let current = neighbour else { continue }
            adoptions.append(Adoption(
                windowId: row.windowId, sessionName: current.session, afterWindowId: current.windowId))
            neighbour = (current.session, row.windowId)
        }
        return adoptions
    }

    /// The tmux commands that carry out `adoptions`, in order. `=session:@id` names the anchor's
    /// place in that session, wherever earlier insertions have moved it.
    static func linkCommands(_ adoptions: [Adoption]) -> [String] {
        adoptions.map { adoption in
            let target = RemoteTmuxHost.shellSingleQuoted("=\(adoption.sessionName):\(adoption.afterWindowId)")
            return "link-window -a -s \(adoption.windowId) -t \(target)"
        }
    }
}
