import Foundation

/// The agent pane a chat's turn changes open in (`chat.changesPane`), one tracker per acpmux
/// session, so every pane on that session asks the same one (Leo 2026-10-21: "why's the diff viewer
/// not opening up in the right split tab?"). The first request opens a tab on the chat's own session
/// right of the chat, on a `changes:` reveal (the page's `CHANGES_REVEAL`,
/// webviews/src/agent-session/acpmux/turnChanges/changesPane.ts); a later one shows its turn in that
/// tab while it is open, instead of opening another. While that tab is still being made, later
/// requests wait for it and the tab shows the newest one, so two quick clicks open one pane. Closing
/// the changes there closes the tab.
@MainActor
public final class AgentChangesPane {
    private var tab: String?
    /// The reveal the tab being made shows once it exists: the newest request's. Nil while none is made.
    private var waiting: String?

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

    /// Starts making the tab for `reveal`; false when one is being made, which then shows `reveal`.
    public func begin(_ reveal: String) -> Bool {
        defer { waiting = reveal }
        return waiting == nil
    }

    /// The tab being made exists as `key`: records it and returns the reveal it shows.
    public func made(_ key: String) -> String? {
        tab = key
        defer { waiting = nil }
        return waiting
    }

    /// The tab being made failed or is done: later requests make or use one again.
    public func ended() { waiting = nil }

    /// The `revealTurn` value that opens a pane on the changes of session `session`'s turn holding
    /// `row`, at `path`: row ids repeat across sessions, so it names the chat too.
    public static func reveal(session: String, row: String, path: String?) -> String {
        "changes:" + session + "\n" + row + (path.map { "\n" + $0 } ?? "")
    }
}
