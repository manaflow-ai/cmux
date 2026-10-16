import Foundation

/// Marks on the windows cmux links into the view, so a bringup can tell its own from others.
///
/// When a session is killed, the windows cmux had linked from it into the view stay alive,
/// linked into the view alone, each with its shell still running; one host had 466 of them.
/// A window created next to a mirrored window by a command that named it only by id also
/// sits in the view alone, but cmux never linked it and it belongs in a real session. A live
/// stream knows which windows it linked. After a reconnect tmux shows the two the same way, so
/// every link also sets a window option named for this view, and the bringup reads it back:
/// a window that carries the mark, or that is still linked into a real session, is cmux's
/// and is unlinked (destroying it when the view holds the last link) once it is no longer
/// wanted. An unmarked window in the view alone is left alone. The option name carries the
/// view's name, because one window can be linked into the views of several cmux installs and a
/// shared value would let them overwrite each other's marks.
///
/// Invariant: every window this connection links into the view is held either by an
/// acknowledged mark in tmux or in ``unconfirmedMarkWindowIds``, and the bringup adopts both.
/// A mark is a tracked write, so tmux's `%error` (or a stream reset) keeps the window in the
/// set; the bringup writes those marks again before it reads the view, and a window whose mark
/// is still refused is adopted from the set. A link whose mark failed therefore cannot become
/// an orphan the bringup refuses to remove. Windows that are gone from the view leave the set.
extension RemoteTmuxViewConnection {
    nonisolated static func windowMarkOption(viewSessionName: String) -> String {
        "@cmux_link_\(viewSessionName)"
    }

    nonisolated static func markedBringupListFormat(viewSessionName: String) -> String {
        "#{window_id} #{window_linked} #{\(windowMarkOption(viewSessionName: viewSessionName))}"
    }

    nonisolated static func linkCommands(windowId: String, viewSessionName: String) -> [String] {
        let option = RemoteTmuxHost.shellSingleQuoted(windowMarkOption(viewSessionName: viewSessionName))
        return [
            "link-window -s \(windowId) -t \(RemoteTmuxHost.shellSingleQuoted(viewSessionName))",
            "set-option -w -t \(windowId) \(option) 1",
        ]
    }

    /// Reads `list-windows -F markedBringupListFormat(...)` rows into the placeholder and the windows
    /// that are cmux's. The placeholder is the first window that is neither linked elsewhere nor
    /// marked; see ``readBringupRows(_:)`` for why it is not simply the first row. A view where
    /// no window carries a mark was left by a cmux that did not set them, and keeps that rule.
    ///
    /// `knownMarked` holds windows this connection linked whose mark tmux has not confirmed;
    /// they count as marked.
    nonisolated static func readMarkedBringupRows(
        _ lines: [String], knownMarked: Set<String> = []
    ) -> (placeholder: String?, adopted: Set<String>, unmarkedLinked: [String]) {
        let rows = lines.compactMap { line -> (id: String, isLinked: Bool, mark: String)? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                .map(String.init)
            guard let id = fields.first, !id.isEmpty else { return nil }
            let mark = knownMarked.contains(id) ? "1" : (fields.count > 2 ? fields[2] : "")
            return (id, fields.count > 1 && fields[1] == "1", mark)
        }
        let unmarkedLinked = rows.filter { $0.isLinked && $0.mark != "1" }.map(\.id)
        guard rows.contains(where: { $0.mark == "1" }) else {
            let legacy = readBringupRows(lines.map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).prefix(2).joined(separator: " ")
            })
            return (legacy.placeholder, legacy.adopted, unmarkedLinked)
        }
        let placeholder = (rows.first { !$0.isLinked && $0.mark != "1" } ?? rows.first)?.id
        var adopted = Set(rows.filter { $0.isLinked || $0.mark == "1" }.map(\.id))
        if let placeholder { adopted.remove(placeholder) }
        return (placeholder, adopted, unmarkedLinked)
    }

    /// Links `windowId` into the view and marks it as linked by this view.
    func linkIntoView(_ conn: RemoteTmuxControlConnection, windowId: String) -> Bool {
        let commands = Self.linkCommands(windowId: windowId, viewSessionName: view.sessionName)
        return conn.send(commands[0]) && markWindow(conn, windowId)
    }

    /// Marks windows cmux holds in a real session that do not carry this view's mark yet, so the
    /// next bringup still knows them as cmux's if their session is killed meanwhile.
    func markLinkedWindows(_ conn: RemoteTmuxControlConnection, _ windowIds: [String]) {
        for windowId in windowIds { _ = markWindow(conn, windowId) }
    }

    /// Writes the marks tmux has not confirmed again. Sent ahead of the bringup's window query,
    /// so by the time tmux answers the query it has answered these too.
    func rewriteUnconfirmedMarks(_ conn: RemoteTmuxControlConnection) {
        for windowId in unconfirmedMarkWindowIds.sorted() { _ = markWindow(conn, windowId) }
    }

    /// Reads the bringup's window rows, counting a window this connection linked as marked
    /// while its mark is unconfirmed, and forgetting unconfirmed windows the view no longer has.
    func readBringupRowsKeepingUnconfirmedMarks(
        _ conn: RemoteTmuxControlConnection, _ lines: [String]
    ) -> (placeholder: String?, adopted: Set<String>) {
        let present = Set(lines.compactMap { $0.split(separator: " ").first.map(String.init) })
        unconfirmedMarkWindowIds.formIntersection(present)
        let read = Self.readMarkedBringupRows(lines, knownMarked: unconfirmedMarkWindowIds)
        markLinkedWindows(conn, read.unmarkedLinked)
        return (read.placeholder, read.adopted)
    }

    /// Sends the mark as a tracked write; only tmux's `%end` takes the window out of the set.
    private func markWindow(_ conn: RemoteTmuxControlConnection, _ windowId: String) -> Bool {
        unconfirmedMarkWindowIds.insert(windowId)
        let command = Self.linkCommands(windowId: windowId, viewSessionName: view.sessionName)[1]
        return conn.sendTracked(command) { [weak self] accepted in
            if accepted { self?.unconfirmedMarkWindowIds.remove(windowId) }
        }
    }
}
