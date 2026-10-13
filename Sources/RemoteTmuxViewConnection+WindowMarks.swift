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
    nonisolated static func readMarkedBringupRows(
        _ lines: [String]
    ) -> (placeholder: String?, adopted: Set<String>, unmarkedLinked: [String]) {
        let rows = lines.compactMap { line -> (id: String, isLinked: Bool, mark: String)? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                .map(String.init)
            guard let id = fields.first, !id.isEmpty else { return nil }
            return (id, fields.count > 1 && fields[1] == "1", fields.count > 2 ? fields[2] : "")
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
        return conn.send(commands[0]) && conn.send(commands[1])
    }

    /// Marks windows cmux holds in a real session that do not carry this view's mark yet, so the
    /// next bringup still knows them as cmux's if their session is killed meanwhile.
    func markLinkedWindows(_ conn: RemoteTmuxControlConnection, _ windowIds: [String]) {
        for windowId in windowIds {
            _ = conn.send(Self.linkCommands(windowId: windowId, viewSessionName: view.sessionName)[1])
        }
    }
}
