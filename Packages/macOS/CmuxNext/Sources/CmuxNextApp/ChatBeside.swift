import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Open beside (Leo 2026-10-14): what a click in a chat opens goes to the pane right of the chat,
/// the in-app way. The first click with no pane there opens one (a new column right of the chat,
/// as an agent's own browser does, AgentBesidePlacement); every later click adds a tab to that same
/// pane, never another split; a click on what a tab there already shows selects that tab. Keyboard
/// focus stays in the chat. Command-click keeps the old place (``keepsOldPlace``).
///
/// The one entry point for the chat's surfaces: links and PR links (AgentPaneNavigation, through
/// `AgentPaneView.openLinkBeside`), file refs (`onOpenFile`), and the Changes diff.
@MainActor
struct ChatBeside {
    /// What a click opens.
    enum Entity: Equatable {
        /// A web page, in the in-app browser.
        case url(URL)
        /// A file, on its file page.
        case file(URL)
        /// The diff of a repository folder.
        case diff(path: String)
    }

    let services: AppServices

    /// Whether the click that is being handled asks for the old place: Command held.
    static var keepsOldPlace: Bool { NSEvent.modifierFlags.contains(.command) }

    /// Opens `entity` beside chat tab `chat` (a provisional key resolves). False when the chat is in
    /// no pane this app knows; the caller then opens it the old way.
    @discardableResult
    func open(_ entity: Entity, beside chat: String) -> Bool {
        let chat = services.agentTabs.resolve(chat)
        guard let (_, chatPane) = services.locateTab(chat) else { return false }
        let beside = Self.besidePane(of: chatPane, in: services.daemon(for: chatPane).store)
        if let beside, let shown = beside.tabs.first(where: { Self.shows($0, entity) }) {
            // Shown already: select it there; the chat keeps focus.
            services.paneController(for: beside)?.select(StripTabID(shown.id))
            return true
        }
        // A tab of the pane right of the chat names it; with none, the chat's tab with a new column.
        let target = beside.flatMap { $0.tabs.first?.id }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        switch entity {
        case .url(let url):
            invocation.arguments = ["url": .string(url.absoluteString)]
            return services.registry.perform("openBrowser", invocation: invocation)
        case .diff(let path):
            invocation.arguments = ["path": .string(path)]
            return services.registry.perform("openDiffViewer", invocation: invocation)
        case .file(let url):
            // A file the browser previews (an image, a PDF) keeps its old place.
            guard FilePageOpener.kind(for: url) != nil, let pane = services.paneController(for: beside ?? chatPane) else { return false }
            let created = AgentBesidePlacement.placed(invocation, in: pane, then: nil)
            return services.viewers.openFile(url, in: pane, userChose: true, beside: created) == nil
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

    /// Whether `tab` shows `entity`: the same page, file or diff.
    static func shows(_ tab: TabModel, _ entity: Entity) -> Bool {
        switch entity {
        case .url(let url):
            tab.kind == .browser && tab.url.map(Self.comparable) == Self.comparable(url.absoluteString)
        case .file(let url):
            tab.page != nil && tab.pageRoute == url.standardizedFileURL.resolvingSymlinksInPath().path
        case .diff(let path):
            tab.page == "diff" && tab.pageRoute.map { path == $0 || path.hasPrefix($0 + "/") } ?? true
        }
    }

    /// A URL as two tabs on the same page compare: no fragment, no trailing slash.
    private static func comparable(_ url: String) -> String {
        var url = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
