import Foundation

/// The app side of the chat header (`pane.action`, `pane.tabState`): runs a
/// ``AgentPaneModel/headerActions`` id on the chat's tab, a split in `cwd` when given,
/// and reads the tab's state the "..." menu's labels show (`{pinned}`).
public struct AgentPaneHeaderHooks {
    public var run: @MainActor (String, String?) -> Void
    public var tabState: @MainActor () -> [String: Any]
    /// Opens acpmux session `id` in a new split beside the chat's tab (New side chat).
    public var openSide: @MainActor (String) -> Void

    public init(run: @escaping @MainActor (String, String?) -> Void, tabState: @escaping @MainActor () -> [String: Any],
                openSide: @escaping @MainActor (String) -> Void = { _ in }) {
        self.run = run
        self.tabState = tabState
        self.openSide = openSide
    }
}

extension AgentPaneModel {
    /// The app actions the chat header runs on its tab (`pane.action`): the Terminal and Browser
    /// splits and the "..." menu's tab verbs.
    public static let headerActions: Set<String> = [
        "splitRight", "splitBrowserRight", "renameTab", "palette.toggleTabPin",
        "moveSurfaceToPaneRight", "palette.moveTabToNewWorkspace", "closeTab",
    ]

    /// `pane.action` runs a listed action on a chat (never the New Tab page); `pane.tabState`
    /// reads the tab's pin; `chat.archive` tags the pane's session and, archiving, closes its tab.
    func respondToHeader(_ request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .paneAction(let id, let cwd):
            guard newTab == nil, Self.headerActions.contains(id), let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action")
            }
            header.run(id, cwd)
            return AgentPaneReply.success()
        case .tabState:
            guard let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.tabState")
            }
            return AgentPaneReply.success(header.tabState())
        case .archive(let archived):
            return await archive(archived)
        case .sideChat(let fork):
            return await openSideChat(fork)
        default:
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request")
        }
    }

    /// Archive sets acpmux's `archived` tag on this pane's session (the lists hide it; its value
    /// is when, in milliseconds), Unarchive removes it. The tab closes only once the tag is set.
    private func archive(_ archived: Bool) async -> [String: Any] {
        guard let sessionId, newTab == nil else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.archive")
        }
        let now = String(Int64(Date().timeIntervalSince1970 * 1000))
        do {
            try await transport.tagSession(sessionId, archived ? [Self.archivedTag: now] : [:], archived ? [] : [Self.archivedTag])
        } catch {
            return AgentPaneReply.failure(code: "failed", message: "\(error)")
        }
        if archived { header?.run("closeTab", nil) }
        return AgentPaneReply.success()
    }

    /// New side chat: `fork` must be a session this pane made (its fork's reply put it in the
    /// pane's scope), never the chat itself. It is tagged `side` with the chat's session, which
    /// keeps it off the lists, then opened in a split beside the chat.
    private func openSideChat(_ fork: String) async -> [String: Any] {
        guard let sessionId, newTab == nil, fork != sessionId, transport.sessions.contains(fork), let header else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.sideChat")
        }
        do {
            try await transport.tagSession(fork, [Self.sideTag: sessionId], [])
        } catch {
            return AgentPaneReply.failure(code: "failed", message: "\(error)")
        }
        header.openSide(fork)
        return AgentPaneReply.success()
    }

    /// The tag the pane's lists read (sessionList.ts `ARCHIVED_TAG`).
    static let archivedTag = "archived"
    /// The tag that marks a side chat, valued with its chat's session (sessionList.ts `SIDE_TAG`).
    static let sideTag = "side"
}
