import Foundation

/// The agent pane a chat's turn changes open in (`chat.changesPane`), one tracker per acpmux
/// session, so every pane on that session asks the same one (Leo 2026-10-21: "why's the diff viewer
/// not opening up in the right split tab?"). The first request opens a tab on the chat's own session
/// right of the chat, on a `changes:` reveal (the page's `CHANGES_REVEAL`,
/// webviews/src/agent-session/acpmux/turnChanges/changesPane.ts); a later one shows its turn in that
/// tab while it is open, instead of opening another. Closing the changes there closes the tab.
@MainActor
public final class AgentChangesPane {
    private var tab: String?

    public init() {}

    private static var sessions: [String: AgentChangesPane] = [:]

    /// The tracker of acpmux session `id`, shared by every tab on that session.
    public static func session(_ id: String) -> AgentChangesPane {
        if let pane = sessions[id] { return pane }
        let pane = AgentChangesPane()
        sessions[id] = pane
        return pane
    }

    /// The open changes tab; `isOpen` says whether a tab key still exists.
    public func tab(isOpen: (String) -> Bool) -> String? {
        if let tab, !isOpen(tab) { self.tab = nil }
        return tab
    }

    /// Records the tab that shows the changes.
    public func record(_ key: String) { tab = key }

    /// The `revealTurn` value that opens a pane on the changes of session `session`'s turn holding
    /// `row`, at `path`: row ids repeat across sessions, so it names the chat too.
    public static func reveal(session: String, row: String, path: String?) -> String {
        "changes:" + session + "\n" + row + (path.map { "\n" + $0 } ?? "")
    }
}
