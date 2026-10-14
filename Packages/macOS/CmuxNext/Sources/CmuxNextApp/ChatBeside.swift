import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon

/// Open beside (Leo 2026-10-14): what a click in a chat opens goes to the pane right of the chat,
/// the in-app way. The first click with no pane there opens one (a new column right of the chat,
/// as an agent's own browser does, AgentBesidePlacement); every later click adds a tab to that same
/// pane, never another split; a click on what a tab there already shows selects that tab. Keyboard
/// focus stays in the chat. Command-click keeps the old place (``keepsOldPlace``).
///
/// The one entry point for the chat's surfaces: links and PR links (`AgentPaneView.openURL`) and
/// file refs (`onOpenFile`); the header's Changes diff joins the same pane (AgentChatSplitToggles).
@MainActor
struct ChatBeside {
    /// What a click opens.
    enum Entity: Equatable {
        /// A web page, in the in-app browser.
        case url(URL)
        /// A file, on its file page.
        case file(URL)
    }

    let services: AppServices

    /// Whether the click that is being handled asks for the old place: Command held. A link click
    /// carries its own modifiers; a file ref's arrives later, so the keys held now stand in.
    static var keepsOldPlace: Bool { (AgentPaneLinkClick.modifiers ?? NSEvent.modifierFlags).contains(.command) }

    /// Opens `entity` beside chat tab `chat` (a provisional key resolves). False when nothing opened
    /// or was selected (the chat is in no pane this app knows, or the page cannot go beside it); the
    /// caller then opens it the old way.
    @discardableResult
    func open(_ entity: Entity, beside chat: String) -> Bool {
        let chat = services.agentTabs.resolve(chat)
        guard let (_, chatPane) = services.locateTab(chat) else { return false }
        let beside = Self.besidePane(of: chatPane, in: services.daemon(for: chatPane).store)
        // A tab of the pane right of the chat names it; with none, the chat's tab with a new column.
        let target = beside.flatMap { $0.tabs.first?.id }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        switch entity {
        case .url(let url):
            if let beside, let shown = beside.tabs.first(where: { Self.shows($0, url) }) {
                // Shown already: select it there; the chat keeps focus.
                guard let pane = services.paneController(for: beside) else { return false }
                pane.select(StripTabID(shown.id))
                return true
            }
            invocation.arguments = ["url": .string(url.absoluteString)]
            return services.registry.perform("openBrowser", invocation: invocation)
        case .file(let url):
            // A file the browser previews (an image, a PDF) keeps its old place.
            guard let kind = FilePageOpener.kind(for: url) else { return false }
            let pages = kind == .markdown ? services.viewers.markdownPages : services.viewers.editorPages
            if let shown = beside.flatMap(services.paneController(for:)), pages.selectShown(url, in: shown) { return true }
            // Only a store tab moves beside the chat; else the old place.
            guard let pane = services.paneController(for: beside ?? chatPane), pages.opensStoreTabs(in: pane) else { return false }
            let placement = invocation
            return services.viewers.openFile(url, in: pane, userChose: true,
                                             beside: { AgentBesidePlacement.placed(placement, in: pane, then: nil) }) == nil
        }
    }

    /// The first pane of the scrolling column right of `chat`'s column: where its clicks open. A dock
    /// never takes them, and a chat in the last column has none (its first click makes one).
    static func besidePane(of chat: PaneModel, in store: DaemonStore) -> PaneModel? {
        guard let screen = store.workspace(containing: chat.handle)?.screens.first(where: { $0.panes.contains { $0 === chat } }),
              let index = screen.columns.firstIndex(where: { $0.layout.paneIDs.contains(chat.handle) }),
              index + 1 < screen.columns.count else { return nil }
        let next = screen.columns[index + 1]
        guard next.dock == nil, let first = next.layout.paneIDs.first else { return nil }
        return screen.panes.first { $0.handle == first }
    }

    /// Whether browser tab `tab` shows `url`: the same page at the same anchor (a link to another
    /// line of a file opens its own tab), whatever the scheme's and host's case or a trailing slash.
    static func shows(_ tab: TabModel, _ url: URL) -> Bool {
        guard tab.kind == .browser, let shown = tab.url.flatMap(URL.init(string:)).flatMap(comparable) else { return false }
        return shown == comparable(url)
    }

    private static func comparable(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        while parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty, parts.host != nil { parts.path = "/" }
        return parts.string
    }
}
