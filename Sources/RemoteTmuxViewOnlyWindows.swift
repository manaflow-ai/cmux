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
        /// The session's `$id`, or "" when the listing had none.
        let sessionId: String
        let afterWindowId: String

        init(windowId: String, sessionName: String, sessionId: String = "", afterWindowId: String) {
            self.windowId = windowId
            self.sessionName = sessionName
            self.sessionId = sessionId
            self.afterWindowId = afterWindowId
        }
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
        var home: [String: (name: String, id: String)] = [:]
        for row in rows where !excludedSessions.contains(row.sessionName) {
            if let current = home[row.windowId], current.name <= row.sessionName { continue }
            home[row.windowId] = (row.sessionName, row.sessionId)
        }
        let viewRows = rows.filter { $0.sessionName == viewSessionName }.sorted { $0.windowIndex < $1.windowIndex }
        var adoptions: [Adoption] = []
        var neighbour: (session: (name: String, id: String), windowId: String)?
        for row in viewRows {
            if let rowHome = home[row.windowId] {
                neighbour = (rowHome, row.windowId)
                continue
            }
            guard row.windowId != placeholderWindowId, !cmuxOwnedWindowIds.contains(row.windowId),
                  let current = neighbour else { continue }
            adoptions.append(Adoption(
                windowId: row.windowId, sessionName: current.session.name, sessionId: current.session.id,
                afterWindowId: current.windowId))
            neighbour = (current.session, row.windowId)
        }
        return adoptions
    }

    /// The tmux commands that carry out `adoptions`, in order, each linking its window and
    /// marking it as cmux's in one sequence. `$session:@window` names the anchor's place in that
    /// session, wherever earlier insertions have moved it. The session goes by its id because
    /// tmux reads a target that starts with `$` as an id, so a session named `$home` cannot be
    /// found by name; `=name` is the fallback when the listing has no id.
    static func linkCommands(_ adoptions: [Adoption]) -> [[String]] {
        adoptions.map { adoption in
            let session = adoption.sessionId.isEmpty ? "=\(adoption.sessionName)" : adoption.sessionId
            let target = RemoteTmuxHost.shellSingleQuoted("\(session):\(adoption.afterWindowId)")
            return RemoteTmuxViewSession.linkAndMark(
                "link-window -a -s \(adoption.windowId) -t \(target)", windowId: adoption.windowId)
        }
    }
}
