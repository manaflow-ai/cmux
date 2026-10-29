import AppKit
import CmuxNextActions
import typealias CmuxNextBridge.StripTabID
import typealias CmuxNextDaemon.SurfaceID
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings

extension InternalPageID {
    /// The Files tree beside a chat (cx-p4rt).
    nonisolated static let files = InternalPageID(rawValue: "files")
}

/// Owns the Files tabs (cx-p4rt): `cmux-page://cmux.files/` pages, one per tab, each showing one
/// folder as a tree (``FileTreePageProvider``). The chat header's Files quick action opens one beside
/// the chat on the chat's folder (``openBeside(folder:chat:target:link:)``, AgentChatSplitToggles); it
/// is off by default until the page is styled, so a person adds it from the header's right-click menu.
/// The daemon keeps only a store tab's page, so a tab restored after a relaunch has no folder and
/// says to open Files from the chat again.
final class FileTreePageService: InternalPageProvider {
    private struct Tab {
        var folder: URL?
        var link: AgentPaneGitLink?
        var page: PageWebView?
        /// The page state its discard kept (PageDiscardState.swift), for the next page's `root` answer.
        var viewState: CmuxNextSettings.JSONValue?
    }

    /// Weak: AppServices owns this service (ViewerService's lazy page services); after it is gone every entry point returns.
    private weak var services: AppServices?
    private var tabs: [String: Tab] = [:]
    /// The clock of the view state deadline (``viewStateTimeout``).
    private let clock: any Clock<Duration>
    /// How long a page may take to say what it shows before its discard goes on without it.
    static let viewStateTimeout: Duration = .seconds(1)

    init(services: AppServices, clock: any Clock<Duration> = ContinuousClock()) {
        self.services = services
        self.clock = clock
    }

    var page: InternalPageID { .files }
    var title: String { FileTreeStrings.title }
    var symbol: String { "folder" }
    var icon: IconName? { .folder }

    func title(for key: String) -> String { tabs[key]?.folder?.lastPathComponent ?? title }

    /// Opens a Files tab on `folder` where an agent's diff opens beside chat tab `chat`
    /// (AgentBesidePlacement): in tab `target`'s column, or with no target in a new column right of
    /// the chat. A person clicked it, so the tab takes the focus. `link` reads the folder on the
    /// chat's own machine.
    func openBeside(folder: URL, chat: String, target: String?, link: AgentPaneGitLink?) {
        guard let services, let pane = pane(showing: target ?? chat) else { return }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        invocation.besideTakesFocus = true
        let created = AgentBesidePlacement.placed(invocation, in: pane, then: nil)
        let key = LocalPageTab.makeKey(.files)
        tabs[key] = Tab(folder: folder, link: link)
        if let window = services.windowController(showing: pane),
           services.pages.openStoreTab(.files, in: pane, window: window, focus: false, key: key, created: created) != nil {
            return
        }
        services.pages.open(.files, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: services.windowController(showing: pane), key: key)
        pane.apply(pane.snapshot())
    }

    /// The pane of any window whose strip holds tab `id`.
    private func pane(showing id: String) -> PaneController? {
        guard let services else { return nil }
        for window in services.windows.controllers {
            if let pane = window.content?.panes.values.first(where: { $0.stripModel.tab(StripTabID(id)) != nil }) { return pane }
        }
        return nil
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        var tab = tabs[key] ?? Tab()
        let provider = FileTreePageProvider(folder: tab.folder, link: tab.link) { [weak self] file in
            self?.open(file, from: key)
        }
        provider.viewState = tab.viewState
        tab.viewState = nil
        let native = AppPageNativeProvider(services: services, page: .files)
        let routes = [PageRoute(prefix: "cmux.files.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = services.webUI.open(PageOpenRequest(descriptor: .files, routes: routes)) else { return NSView() }
        native.anchor = { [weak page] in page }
        tab.page = page
        tabs[key] = tab
        return page
    }

    func tabClosed(_ key: String) {
        tabs.removeValue(forKey: key)?.page?.close()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, as Chrome's proactive discards (proactive_discarding_policy.cc). The tree
    /// is a read-only listing: the next page lists the folder again and opens the folders the last
    /// one had open, with its selection and scroll (`cmux.files.viewState`).
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// Asks the page for its open folders, selected row and scroll. A page that does not answer in
    /// time comes back at its root.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let page = tabs[key]?.page else { return ContentViewState() }
        let answer = await PageAnswerDeadline(Self.viewStateTimeout, clock: clock).answer {
            try await page.router.callPage("cmux.files.viewState", params: .object([:]))
        }
        guard let answer, answer != .null, tabs[key]?.page === page else { return ContentViewState() }
        return ContentViewState(page: answer)
    }

    /// The page gets its state in its `root` answer (``makeView(for:in:)``), not from its view.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {}

    func willRemakeView(for key: String, with state: ContentViewState) {
        tabs[key]?.viewState = state.page
    }

    /// Tab `key`'s page goes; the tab keeps its folder and git link.
    func viewDiscarded(_ key: String) {
        tabs[key]?.page?.close()
        tabs[key]?.page = nil
    }

    /// Opens `file` from tab `key`'s tree in the file pages (FilePageOpener), in the tree's pane. Nil,
    /// or why it did not open.
    private func open(_ file: URL, from key: String) -> String? {
        guard let services else { return FileTreeStrings.unavailable }
        return services.viewers.fileOpener.open(file, in: services.paneController(showingTab: key))
    }
}
