import AppKit
import CmuxNextActions
import Foundation

/// The app side of the chat header (`pane.action`, `pane.tabState`): runs a
/// ``AgentPaneModel/headerActions`` id on the chat's tab, a split in `cwd` when given,
/// toggles a quick action's split (`mode: "toggle"`: close the one it opened, else open),
/// and reads the header's state (``AgentPaneHeaderState``: the pin the "..." menu's labels show,
/// whether the panes beside the chat show, and which toggles are lit).
public struct AgentPaneHeaderHooks {
    public var run: @MainActor (String, String?) -> Void
    public var toggle: @MainActor (String, String?) -> Void
    public var tabState: @MainActor () -> AgentPaneHeaderState
    /// Opens side session `fork` of chat session `chat` beside the chat's tab (New side chat, a
    /// `/btw` side session): a tab in the chat's side pane when one is open, else a new split
    /// (``AgentSidePanes``).
    public var openSide: @MainActor (_ chat: String, _ fork: String) -> Void
    /// Opens acpmux session `id` on the chat's right as a link opens (`layout.linkPlacement`): a
    /// tab in the pane on its right, else a new split there; false when nothing opened.
    public var openRight: @MainActor (String) -> Bool
    /// Opens acpmux session `id` (a fork, a started Continue In…) at a ``AgentForkDestination``: a
    /// new tab beside the chat's, a split beside it, a new workspace or a new window, so the chat
    /// keeps its own tab and session; false when nothing opened.
    public var openTab: @MainActor (String, AgentForkDestination) -> Bool
    /// Shows subagent `agent` of session `session` in an agent pane right of the chat
    /// (``AgentSubagentPanes``), focused with `focus`; false when no pane opened.
    public var openSubagent: @MainActor (_ session: String, _ agent: String, _ focus: Bool) -> Bool
    /// Opens `viewer` (a background process's read-only terminal) in a tab beside the chat; false
    /// when no tab opened.
    public var openProcess: @MainActor (_ viewer: AgentPaneProcessViewer) -> Bool
    /// A started chat's New Chat Here: a New Tab page in folder `cwd`, in a tab beside the chat's;
    /// false when none opened.
    public var newChat: @MainActor (String) -> Bool
    /// [+] New tab / Hide tabs: opens, hides or shows the panes beside the chat; whether they show
    /// after it, nil when it could not run.
    public var sideTabs: @MainActor () -> Bool?
    /// Preview: toggles (`true`) or opens a browser tab beside the chat on a local page.
    public var preview: @MainActor (String?, Bool) -> Void
    /// The right-click menu's quick actions, saved to `agent-pane/layout.json`; whether they were.
    public var saveQuickActions: @MainActor ([AgentPaneQuickAction]) async -> Bool
    /// The "..." menu's Move to Floating Chat (cx-b9qi): Start Agent's panel holds session `id` and
    /// the tab closes; false when it could not (the floating chat is off).
    public var moveToFloatingChat: (@MainActor (String) -> Bool)?
    /// Asks for the chat folder's pull request again (`pane.tabState {refresh: true}` at a turn's
    /// end, cx-ncc.77.1); the answer is pushed with the header state.
    public var refreshPullRequest: (@MainActor () -> Void)?
    /// Shows and focuses the tab that shows acpmux session `id` already, so a chat never streams in
    /// two tabs (``AgentPaneOfferOpen``); false when no tab shows it.
    public var showSession: @MainActor (String) -> Bool
    /// Whether acpmux session `session` is of chat `chat`'s family: a sub-session it started at any
    /// depth, or the session that started it (acpmux `startedBy`, mirrored by the app's turn-state
    /// watch). ``AgentPaneOfferOpen`` opens only those, or the pane's own sessions; none by default.
    public var isFamily: @MainActor (_ session: String, _ chat: String) -> Bool
    /// Changes with a chat turn (``AgentPaneDiffTurn``): the diff beside the chat with that turn
    /// as its Last turn, toggled (`true`) or opened. Nil: the header runs Changes without it.
    public var diffTurn: (@MainActor (_ cwd: String?, _ turn: AgentPaneDiffTurn, _ toggle: Bool) -> Void)?

    public init(run: @escaping @MainActor (String, String?) -> Void,
                toggle: (@MainActor (String, String?) -> Void)? = nil,
                tabState: @escaping @MainActor () -> AgentPaneHeaderState,
                openSide: @escaping @MainActor (String, String) -> Void = { _, _ in },
                openRight: @escaping @MainActor (String) -> Bool = { _ in false },
                openTab: @escaping @MainActor (String, AgentForkDestination) -> Bool = { _, _ in false },
                openSubagent: @escaping @MainActor (String, String, Bool) -> Bool = { _, _, _ in false },
                openProcess: @escaping @MainActor (AgentPaneProcessViewer) -> Bool = { _ in false },
                newChat: @escaping @MainActor (String) -> Bool = { _ in false },
                sideTabs: @escaping @MainActor () -> Bool? = { nil },
                preview: @escaping @MainActor (String?, Bool) -> Void = { _, _ in },
                saveQuickActions: (@MainActor ([AgentPaneQuickAction]) async -> Bool)? = nil,
                moveToFloatingChat: (@MainActor (String) -> Bool)? = nil,
                refreshPullRequest: (@MainActor () -> Void)? = nil,
                showSession: @escaping @MainActor (String) -> Bool = { _ in false },
                isFamily: @escaping @MainActor (_ session: String, _ chat: String) -> Bool = { _, _ in false }) {
        self.run = run
        self.toggle = toggle ?? run
        self.tabState = tabState
        self.openSide = openSide
        self.openRight = openRight
        self.openTab = openTab
        self.openSubagent = openSubagent
        self.openProcess = openProcess
        self.newChat = newChat
        self.sideTabs = sideTabs
        self.preview = preview
        self.saveQuickActions = saveQuickActions ?? { _ in false }
        self.moveToFloatingChat = moveToFloatingChat
        self.refreshPullRequest = refreshPullRequest
        self.showSession = showSession
        self.isFamily = isFamily
    }

    /// The header's state (`pane.tabState`); `refresh` first asks for the pull request again.
    @MainActor func state(refresh: Bool) -> AgentPaneHeaderState {
        if refresh { refreshPullRequest?() }
        return tabState()
    }

    /// The "..." menu's Move to Floating Chat (`pane.action {id: "floatingChat"}`).
    static let floatingChatAction = "floatingChat"

    /// The header's `pane.action` ids that are not app actions on its tab, for chat `session` (nil:
    /// the New Tab page): Move to Floating Chat. Nil for any other id.
    @MainActor func respond(toOther id: String, session: String?) -> [String: Any]? {
        guard id == Self.floatingChatAction else { return nil }
        guard let session, let moveToFloatingChat, moveToFloatingChat(session) else {
            return AgentPaneReply.failure(code: "unavailable", message: "The floating chat is off")
        }
        return AgentPaneReply.success()
    }
}

extension AgentPaneModel {
    /// The app actions the chat header runs on its tab (`pane.action`): the Terminal, Split Down and
    /// Browser splits, Changes' diff, Files' tree (not an app action) and the "..." menu's tab verbs. Preview has its own request.
    public static let headerActions: Set<String> = [
        "splitRight", "splitDown", "splitBrowserRight", "openDiffViewer", "files", "renameTab", "palette.toggleTabPin",
        "moveSurfaceToPaneRight", "palette.moveTabToNewWorkspace", "tab.moveToNewWindow", "closeTab",
    ]

    /// The header's Changes, the diff viewer beside the chat.
    static let diffAction = "openDiffViewer"
    /// The header's [+] New tab / Hide tabs (`pane.action {id: "sideTabs"}`), answered with `{shown}`.
    static let sideTabsAction = "sideTabs"
    /// The header's Preview (`pane.action {id: "preview", url}`), ``AgentPaneRequest/preview(url:toggle:)``.
    public static let previewAction = "preview"

    /// `pane.action` runs a listed action on a chat (never the New Tab page); `pane.tabState`
    /// reads the header's state. Archive and Mark as Unread are the page's own acpmux requests
    /// (`_acpmux/archive`, `_acpmux/markUnread`, cx-jlzsf); Archive then closes the tab with `pane.action`.
    func respondToHeader(_ request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .paneAction(Self.sideTabsAction, _, _):
            guard newTab == nil, let shown = header?.sideTabs() else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action sideTabs")
            }
            return AgentPaneReply.success(["shown": shown])
        case .preview(let url, let toggle):
            guard newTab == nil, let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action preview")
            }
            header.preview(url, toggle)
            return AgentPaneReply.success()
        case .setQuickActions(let list):
            guard newTab == nil, let header, await header.saveQuickActions(list) else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.setQuickActions")
            }
            return AgentPaneReply.success()
        case .paneAction(let id, let cwd, let toggle):
            guard newTab == nil, Self.headerActions.contains(id), let header else {
                return header?.respond(toOther: id, session: newTab == nil ? sessionId : nil) ?? AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action")
            }
            // The Terminal split names the chat's folder; agent-home is the chat's only.
            let folder = folderForOtherTabs(cwd)
            if toggle { header.toggle(id, folder) } else { header.run(id, folder) }
            // `ran`: the page knows the App took the action (a host without panes, such as the
            // gallery, answers null), so its diff link opens the diff beside the chat, not in place.
            return AgentPaneReply.success(["ran": true])
        case .diffTurn(let turn, let cwd, let toggle):
            guard newTab == nil, let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.action")
            }
            let folder = folderForOtherTabs(cwd)
            if let diffTurn = header.diffTurn { diffTurn(folder, turn, toggle) }
            else if toggle { header.toggle(Self.diffAction, folder) } else { header.run(Self.diffAction, folder) }
            return AgentPaneReply.success(["ran": true])
        case .tabRowTools(let width):
            tabRow.report(width: CGFloat(width)) // used only while chrome.tabs.rowTools is on and the pane offered the row
            return AgentPaneReply.success()
        case .tabState(let refresh):
            guard let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: pane.tabState")
            }
            var state = header.state(refresh: refresh).reply
            state["moves"] = offeredMoves()
            return AgentPaneReply.success(state)
        case .sideChat(let fork):
            return await AgentPaneSideChat.open(fork, in: self)
        case .subagentPane(let agent, let focus):
            // The chat's own subagent, in a pane of its own; not from a New Tab page. A refusal
            // answers `opened: false`, and the page shows the subagent in this pane instead.
            guard let sessionId, newTab == nil, let header else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.subagentPane")
            }
            return AgentPaneReply.success(["opened": header.openSubagent(sessionId, agent, focus)])
        case .processTerminal(let call):
            return AgentPaneProcessViewer.open(call, in: self)
        case .chatTab(let chat, let destination):
            // Only a chat this pane made (its fork's or handoff start's reply put it in the pane's
            // scope), never the chat itself, and not from a New Tab page. A refusal (another
            // machine's pane, no daemon) answers so: the page then opens the chat in this tab.
            guard let sessionId, newTab == nil, chat != sessionId, AgentPaneSideChat.holds(chat, chat: sessionId, in: self), let header,
                  header.openTab(chat, destination) else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.openTab")
            }
            return AgentPaneReply.success()
        case .offerOpen(let session, let sender):
            return AgentPaneOfferOpen.respond(session, sender: sender, in: self)
        case .asksOpen(let session):
            return AgentPaneAskOpen.respond(session, in: self)
        case .asksAnswer(let ask):
            return await ask.respond(in: self)
        case .newChatHere(let cwd):
            guard sessionId != nil, newTab == nil, let header, header.newChat(cwd) else {
                return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.newHere")
            }
            return AgentPaneReply.success()
        default:
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request")
        }
    }
}

/// New side chat's view part: opens `fork` in the chat's one side pane, tagged its side chat by
/// acpmux (`_acpmux/side` or `_acpmux/btw`, cx-jlzsf). `fork` must be a session this pane made (its
/// reply put it in the pane's scope), or, for a chat on another machine, one that chat started there
/// (its daemon listed it, ``RemoteAgentSessionLinks``); never the chat itself. Kept off
/// ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneSideChat {
    /// True when the pane of chat `chat` may open `session` beside it.
    static func holds(_ session: String, chat: String, in model: AgentPaneModel) -> Bool {
        if model.transport.sessions.contains(session) { return true }
        guard model.remoteChat, let host = model.transport.remoteHostID else { return false }
        return RemoteAgentSessionLinks.shared.descends(session, from: chat, host: host)
    }

    static func open(_ fork: String, in model: AgentPaneModel) async -> [String: Any] {
        guard let sessionId = model.sessionId, model.newTab == nil, fork != sessionId, holds(fork, chat: sessionId, in: model),
              let header = model.header else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.sideChat")
        }
        header.openSide(sessionId, fork)
        return AgentPaneReply.success()
    }
}

extension AgentPaneModel {
    /// The Cloud moves (`cloudMove`, `cloudBringBack`) the chat's right-click menu offers now, so the
    /// composer's picker offers the same: the App decides which apply (it hides Bring Back Local on a
    /// chat no move from this Mac put on its machine, and Move to Cloud on a chat of another machine).
    func offeredMoves() -> [String] {
        func ids(_ items: [NSMenuItem]) -> [String] {
            items.flatMap { item in
                (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + ids(item.submenu?.items ?? [])
            }
        }
        let moves: Set<String> = ["cloudMove", "cloudBringBack"]
        return ids(chatMenuItems?() ?? []).filter(moves.contains)
    }
}
