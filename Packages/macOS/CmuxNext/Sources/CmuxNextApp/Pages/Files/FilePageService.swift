import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings
import Foundation
import CmuxNextWakeups
import typealias CmuxNextDaemon.SurfaceID

/// Owns one file page's tabs (diff-host S6 `cmux.markdown`, S7 `cmux.editor`): pane tabs, one
/// ``FilePageProvider`` and page view per tab, one shared look per page (its settings section,
/// `<config dir>/<section>/theme.css`, the editor's syntax theme and language pack). Both pages use
/// this one service type; ``FilePageKind`` says where they differ.
///
/// Entry points: ``open(_:in:focus:)`` (the file routing, ``FilePageOpener``, behind Open File...,
/// the picker, `file.open`, links and drops) and ``openEmpty(in:focus:)`` (the empty state, where
/// the page lists recents, asks the picker or takes a dropped file). Every open records the file
/// in the viewers' recents (R89).
final class FilePageService: InternalPageProvider {
    struct Tab {
        var file: URL?
        /// The user opened the document (not an agent or a script): it is granted and writable.
        var userChose = true
        /// The host opens the document read only (a chat transcript).
        var readOnly = false
        var page: PageWebView?
        var provider: FilePageProvider?
        var host: FilePageTabHost?
        /// A recovered crash draft for the page to load as an unsaved edit.
        var recoveredText: String?
        /// Where the editor's first config puts the cursor (a Find result), until the page asks.
        var reveal: FilePosition?
        /// Ends this tab's flush registration on its quit document.
        var stopFlush: (() -> Void)?
        /// The Markdown omnibar above the page (markdown tabs only).
        var bar: MarkdownOmnibarBar?
        /// After a discard (FilePageService+Discard.swift): the page state it kept, for the next
        /// page's first config, and what the last page could open and save.
        var viewState: JSONValue?
        var access: FileWorkspaceRoots.Grants?
        /// The page reported edits that are not on disk, whatever the quit hook made of them.
        var editsUnsaved = false
    }

    let kind: FilePageKind
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    let clock: any Clock<Duration>
    private let images: any RemoteImageFetching
    var tabs: [String: Tab] = [:]
    /// Markdown table column widths between opens (the file's extended attribute, then an app-side copy).
    private let tableWidths: (any MarkdownTableWidthStoring)?
    /// Where the markdown tabs keep viewer comments (viewer-comments-DESIGN.md "Comments in the viewer").
    private let comments: (any MarkdownCommentStoring)?
    private(set) lazy var look = FilePageLook(kind: kind, settings: { [servicesReference] in servicesReference.resolve()?.settings },
                                              mainWork: mainWork, work: work)
    /// The documents of the R96 quit hook (one per file, shared with the other file page).
    let documents: FileQuitDocuments
    /// Files whose draft is over the store's limit and that already said so.
    var warnedTooLarge: Set<String> = []
    /// Pages saving or reporting their last edits after their tab closed or was discarded.
    var flushing: [UUID: Task<Void, Never>] = [:]
    /// Replies to the tabs' async calls (a selection read, an open), each on its tab's node queue: held
    /// while the tab is hidden, dropped when it closes.
    private(set) lazy var replies = PageTabReplies(owner: "\(kind.namespace).page-reply", on: mainWork) { [servicesReference] key in
        servicesReference.resolve().map { $0.cache.node(for: $0.pages.stripTab(ofKey: key)) }
    }
    /// The local live links of the Markdown Share menu, started on the first link.
    private(set) lazy var liveShare = MarkdownLiveShareServer(work: work, deadlines: mainDeadlines)
    /// The app's background work (``AppServices/work``), which the live share server runs on.
    private let work: BackgroundWork
    /// The app's main-thread work scheduler (``AppServices/mainWork``), read when the service is made.
    private let mainWork: MainWorkScheduler
    /// The app's main-thread deadlines (``AppServices/mainDeadlines``), which the live share server's timers use.
    private let mainDeadlines: MainDeadlineScheduler

    /// The file pages draw at the display's full rate, as the diff and agent pages do.
    static let engineOptions = PageEngineOptions(fullFrameRate: true)
    /// How long a closed editor tab's page may take to save its pending edits.
    static let flushTimeout: Duration = .seconds(3)

    init(services: AppServices, kind: FilePageKind, clock: any Clock<Duration> = ContinuousClock(),
         images: (any RemoteImageFetching)? = nil, documents: FileQuitDocuments? = nil,
         tableWidths: (any MarkdownTableWidthStoring)? = nil) {
        servicesReference = OwnerReference(services: services)
        work = services.work
        mainWork = services.mainWork
        mainDeadlines = services.mainDeadlines
        self.tableWidths = kind == .markdown
            ? tableWidths ?? MarkdownTableWidthRepository(fallback: MarkdownTableWidthRepository.defaultFallbackDirectory())
            : nil
        self.comments = kind == .markdown
            ? MarkdownCommentRepository(storage: MarkdownTableWidthRepository(
                fallback: MarkdownTableWidthRepository.defaultFallbackDirectory(folder: "MarkdownComments"),
                name: MarkdownTableWidthRepository.commentsAttributeName,
                maxBytes: MarkdownTableWidthRepository.commentsValueLimit))
            : nil
        self.documents = documents ?? services.fileQuitDocuments
        self.kind = kind
        self.clock = clock
        self.images = images ?? GuardedRemoteImages(lanes: services.work) // nil: the guarded fetch, its lookup on the app's lanes
    }

    var page: InternalPageID { kind.page }
    var title: String { kind.title }
    var symbol: String { kind.symbol }
    var icon: IconName? { kind.icon }

    func title(for key: String) -> String { tabs[key]?.file?.lastPathComponent ?? title }

    /// The file the tab opened on (page-tab-route-v1); a later open inside the page keeps the first.
    func route(for key: String) -> String? { tabs[key]?.file?.path }

    /// A store tab came back on `route` (Reopen Closed, relaunch). The daemon
    /// gave the path, so it is granted only as a recent file is
    /// (`FilePageProvider`'s recents grant); any other path opens as an open
    /// the user did not choose.
    func restore(_ route: String, for key: String) {
        guard tabs[key] == nil, route.hasPrefix("/") else { return }
        tabs[key] = Tab(file: URL(fileURLWithPath: route), userChose: isRecent(route))
    }

    func pageView(_ key: String) -> PageWebView? { tabs[key]?.page }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Each tab's key, file and page, for `debug.filepages`.
    var debugTabs: [(key: String, file: URL?, page: PageWebView?)] {
        tabs.keys.sorted().map { ($0, file($0), tabs[$0]?.page) }
    }
    #endif

    func provider(_ key: String) -> FilePageProvider? { tabs[key]?.provider }

    /// The tab showing `page` (the focused page) is one of this page's tabs, read only (the config
    /// its provider last served said so): `markdownReadOnlyFocused` (K1).
    func showsReadOnly(on page: PageWebView) -> Bool {
        tabs.values.contains { $0.page === page && $0.provider?.showsReadOnly == true }
    }

    /// Whether the tab showing `page` waits for the second key of a key sequence
    /// (``FilePageProvider/keySequencePending``).
    func keySequencePending(on page: PageWebView) -> Bool {
        tabs.values.contains { $0.page === page && $0.provider?.keySequencePending == true }
    }

    /// The file tab `key` shows, nil for the empty state or another tab.
    func file(_ key: String) -> URL? { tabs[key]?.provider?.file ?? tabs[key]?.file }

    /// Opens `file` in a tab after `pane`'s selected tab, or selects the tab of `pane`'s window that
    /// already shows it. A user run (`focus`) selects and focuses it. `readOnly`: the tab never saves
    /// the file (a chat transcript); every other markdown file opens writable. `position` (the code
    /// editor only, a Find result): the cursor goes there, in a new tab after its load
    /// (``revealAt(_:in:)``).
    @discardableResult
    func open(_ file: URL, in pane: PaneController, focus: Bool, userChose: Bool = true, readOnly: Bool = false,
              recoveredText: String? = nil, at position: FilePosition? = nil,
              placed: (@MainActor (SurfaceID) -> Void)? = nil) -> String {
        guard let services else { return "" }
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        if userChose { services.viewers.recents.record(real, as: kind.recents) }
        let reveal = kind == .editor ? position : nil
        let tab = Tab(file: real, userChose: userChose, readOnly: readOnly, recoveredText: recoveredText, reveal: reveal)
        let key = show(in: pane, focus: focus, placed: placed, tab) { key in
            self.file(key) == real
        }
        if let reveal { revealAt(reveal, in: key) }
        // The user opened a file a tab already shows (perhaps one an agent opened): it is theirs now.
        if userChose {
            tabs[key]?.userChose = true
            tabs[key]?.provider?.userChose(real)
        }
        // A tab that already showed the file takes the draft on its next config.
        if let recoveredText, let provider = tabs[key]?.provider, provider.recoveredText == nil, tabs[key]?.page != nil {
            provider.recoveredText = recoveredText
            tabs[key]?.page?.reload()
        }
        return key
    }

    /// Puts tab `key`'s cursor at `position`: a tab whose page is up gets the `reveal` page command;
    /// a tab whose page is not made yet (or takes no commands yet) carries it into its first config.
    private func revealAt(_ position: FilePosition, in key: String) {
        guard tabs[key] != nil else { return }
        if let page = tabs[key]?.page, let provider = tabs[key]?.provider {
            if page.send(command: EditorPageCommand.reveal, arguments: ["text": .string(position.pageText)]) {
                tabs[key]?.reveal = nil
                provider.reveal = nil
            } else {
                provider.reveal = position
            }
        } else {
            tabs[key]?.reveal = position
        }
    }

    /// Tab `key` as a holder of its quit document (the markdown and editor pages share documents).
    func holder(_ key: String) -> String { kind.namespace + ":" + key }

    /// Tab `key` stops showing `url`: the tab's flush goes; the document goes with the last tab.
    private func left(_ url: URL?, tab key: String) {
        tabs[key]?.stopFlush?()
        tabs[key]?.stopFlush = nil
        guard let url else { return }
        documents.release(url, holder: holder(key))
    }

    /// Opens (or selects) the window's empty tab of this page.
    @discardableResult
    func openEmpty(in pane: PaneController, focus: Bool) -> String {
        show(in: pane, focus: focus, Tab(file: nil)) { key in self.file(key) == nil }
    }

    /// The tab opens as a store tab where the pane's daemon holds page tabs
    /// (page-tabs-v1), on its file as the route (page-tab-route-v1), so it
    /// moves like any daemon tab and Reopen Closed brings it back on that
    /// file; else as an app-only tab.
    /// `placed` (``LinkOpener``): a new store tab opens unselected and reports its surface there; a
    /// tab that already shows the file, or a local tab no move can take, shows where it is.
    private func show(in pane: PaneController, focus: Bool, placed: (@MainActor (SurfaceID) -> Void)? = nil, _ tab: Tab,
                      matching: (String) -> Bool) -> String {
        guard let services else { return "" }
        let window = services.windowController(showing: pane)
        let revealsExisting = focus || placed != nil
        for candidate in window?.content?.panes.values.map({ $0 }) ?? [pane] {
            let keys = services.pages.tabIDs(in: candidate.paneKey) + candidate.pane.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            if let shown = keys.first(where: { tabs[$0] != nil && matching($0) }) {
                if revealsExisting { reveal(shown, in: candidate) }
                return shown
            }
            // A store tab of the same file that has not been shown yet (relaunch): show it, not a second one.
            if let file = tab.file?.path, let unshown = candidate.pane.tabs.first(where: {
                $0.page == kind.page.rawValue && $0.pageRoute == file && services.pages.storeKey(of: $0.id) == nil
            }) {
                if revealsExisting {
                    candidate.select(StripTabID(unshown.id))
                    candidate.focusContent()
                }
                return unshown.id
            }
        }
        let key = LocalPageTab.makeKey(kind.page)
        tabs[key] = tab
        // A store tab only on this Mac's daemon that keeps the route: a file path of this Mac never
        // goes to another machine's daemon, and a tab without its route could not come back.
        if let window, pane.daemon.isLocal, services.pages.keepsRoutes(pane.daemon),
           services.pages.openStoreTab(kind.page, in: pane, window: window, focus: focus, key: key, created: placed) != nil {
            return key
        }
        services.pages.open(kind.page, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: window, key: key)
        pane.apply(pane.snapshot())
        if revealsExisting { reveal(key, in: pane) }
        return key
    }

    private func reveal(_ key: String, in pane: PaneController) {
        guard let services else { return }
        pane.select(services.pages.stripID(showing: key, in: pane) ?? StripTabID(key))
        pane.focusContent()
    }

    /// Tab `key`'s page history moved: its omnibar's Back and Forward follow.
    func historyChanged(canBack: Bool, canForward: Bool, in key: String) {
        tabs[key]?.bar?.setHistory(canBack: canBack, canForward: canForward)
    }

    /// Tab `key` now shows `url` (an open in the page): retitle it.
    func opened(_ url: URL, in key: String) {
        if let previous = tabs[key]?.file, previous != url { left(previous, tab: key) }
        tabs[key]?.file = url
        tabs[key]?.bar?.show(url)
        if let pane = services?.paneController(showingTab: key) { pane.apply(pane.snapshot()) }
    }

    fileprivate func pane(of key: String) -> PaneController? {
        guard let services else { return nil }
        return services.paneController(showingTab: key) ?? services.windows.active?.focusedPane
    }

    // MARK: Host services for the tabs

    /// The "Open <path>?" sheet for links outside a granted folder: one at a time, after a real
    /// user gesture on a file page.
    private(set) lazy var openConfirmation = FileOpenConfirmation()

    func isRecent(_ path: String) -> Bool {
        guard let services else { return false }
        let recents = services.viewers.recents
        return recents.paths(.markdown).contains(path) || recents.paths(.file).contains(path)
    }

    /// A web link clicked in the page: the link setting (``LinkRouter``, cmux browser or the default
    /// browser) and, in cmux, beside the page's pane (``LinkOpener``).
    func openExternal(_ url: URL, from key: String) {
        guard let services else { return }
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard LinkRouter.shared.target(for: url) == .cmuxBrowser else { return LinkRouter.shared.open(url, in: .system) }
            if let pane = pane(of: key) { services.linkOpener.openWeb(url, from: pane, background: false) } else { NSWorkspace.shared.openInBackground(url) }
        default:
            NSWorkspace.shared.openInBackground(url)
        }
    }

    /// A file link clicked in the page opens beside the page's pane (``LinkOpener``).
    func openFile(_ url: URL, from key: String) {
        guard let services else { return }
        services.linkOpener.openFile(url, from: pane(of: key), markdown: FilePageKind.isMarkdown(url))
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        // A store tab with no route (an empty tab, an older daemon) shows the empty state.
        var tab = tabs[key] ?? Tab(file: nil)
        let host = FilePageTabHost(service: self, key: key)
        let libraries = Bundle.main.resourceURL.map(PageDescriptor.markdownLibraries(inAppResources:))
        if tab.access != nil, tab.recoveredText == nil { tab.recoveredText = unsavedText(of: tab.file) }
        let provider = FilePageProvider(kind: kind, file: tab.file, userChose: tab.userChose, readOnly: tab.readOnly, access: tab.access,
                                        host: host, libraries: libraries, images: images, tableWidths: tableWidths,
                                        comments: comments, deadlines: services.mainDeadlines, work: services.work)
        provider.recoveredText = tab.recoveredText
        provider.reveal = tab.reveal
        provider.viewState = tab.viewState
        tab.recoveredText = nil
        tab.reveal = nil
        tab.viewState = nil
        tab.access = nil
        tab.editsUnsaved = false
        let native = AppPageNativeProvider(services: services, page: kind.descriptor)
        let routes = [PageRoute(prefix: kind.namespace + ".", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = services.webUI.open(PageOpenRequest(descriptor: kind.descriptor, routes: routes, options: Self.engineOptions,
                                                             surface: kind.surface,
                                                             dynamicResources: kind == .markdown ? provider : nil)) else {
            return NSView()
        }
        native.anchor = { [weak page] in page }
        provider.onCommentsChanged = { [weak page] value in
            _ = page?.send(command: MarkdownPageCommand.comments, arguments: ["text": .string(value.compactText)])
        }
        page.onOpenExternal = { [weak self] url in self?.openExternal(url, from: key) }
        page.fileDrop = fileDrop(provider: provider, page: page, key: key)
        // One menu: Copy; Comment…, Quote in Chat, Send to Chief and Send To… on a selection; Reset
        // Column Widths on a table (viewer-comments-DESIGN.md).
        installSelectionMenu(on: page, key: key, then: kind == .markdown ? Self.tableMenu(provider: provider, page: page) : nil)
        tab.page = page
        tab.provider = provider
        tab.host = host
        tabs[key] = tab
        return page
    }

    /// The Markdown omnibar above a markdown tab's page (plans/cmux-next/markdown-omnibar-DESIGN.md):
    /// the browser's omnibar row showing the file's path, its git state and the Share menu.
    func makeTopBar(for key: String) -> NSView? {
        guard let services else { return nil }
        guard kind == .markdown, let tab = tabs[key], let page = tab.page else { return nil }
        let actions = MarkdownOmnibarActions(
            open: { [weak self] url, disposition in self?.omnibarOpen(url, disposition: disposition, from: key) },
            returnFocus: { [weak page] in
                page?.focusPage()
            },
            liveLink: { [weak self] url in try? await self?.liveShare.link(for: url) },
            openInBrowser: { [weak self] url in self?.openExternal(url, from: key) },
            back: { [weak page] in page?.send(command: "back") },
            forward: { [weak page] in page?.send(command: "forward") },
            reload: { [weak page] in page?.send(command: MarkdownPageCommand.reload) })
        let bar = MarkdownOmnibarBar(suggestionEngine: services.cache.suggestionEngine, actions: actions, mainWork: services.mainWork)
        bar.toolbar.cardClip = page
        bar.show(tab.provider?.file ?? tab.file)
        tabs[key]?.bar = bar
        return bar
    }

    /// A URL committed in the Markdown omnibar: a Markdown file opens in this tab as a new history
    /// entry (the user typed it, so it is theirs), another file through the file routing, a web URL
    /// or a search in a browser tab beside the page (the link placement rule, as a clicked link).
    /// A modified commit (`disposition`) always opens a new tab.
    private func omnibarOpen(_ url: URL, disposition: OmnibarDisposition?, from key: String) {
        guard url.isFileURL else { return openExternal(url, from: key) }
        guard disposition == nil, FilePageKind.isMarkdown(url), let provider = tabs[key]?.provider, let page = tabs[key]?.page else {
            return openFile(url, from: key)
        }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        provider.userChose(file)
        // A tab showing a file keeps its history: the page opens the typed one as the next entry.
        if provider.file != nil, page.send(command: MarkdownPageCommand.open, arguments: ["text": .string(file.path)]) { return }
        // The open, then the reload (or the refusal's beep) as a reply on the tab's queue.
        replies.reply(for: key) { (try? await provider.open(url)) != nil } apply: { [weak page] opened in
            guard opened else { return NSSound.beep() }
            page?.reload()
        }
    }

    /// Finder drops (WebKit hides their paths from the page): the empty tab opens the dropped file
    /// in place; a tab with a file sends it through the file routing to its own tab.
    private func fileDrop(provider: FilePageProvider, page: PageWebView, key: String) -> PageFileDrop {
        PageFileDrop(accepts: { url in url.isFileURL && !url.hasDirectoryPath }, open: { [weak self, weak provider, weak page] url in
            guard let self, let provider else { return }
            guard provider.isPicking, provider.kind.accepts(url) else { return self.openFile(url, from: key) }
            // The page keeps its `fileDrop` reason until the open returns (PageFileDrop.take).
            guard (try? await provider.open(url)) != nil else { return NSSound.beep() }
            page?.reload()
        })
    }

    func tabClosed(_ key: String) {
        guard let tab = tabs[key] else { return }
        tabs[key] = nil
        replies.close(key)
        letPageGo(tab, key: key, closing: true)
    }

    /// `tab`'s page goes: a closed tab's (`closing`) or a discarded one's. Its page first saves its
    /// pending edits (`cmux.<page>.flush`; the person's own Hibernate Tab asks nothing before it).
    private func letPageGo(_ tab: Tab, key: String, closing: Bool) {
        let file = tab.provider?.file ?? tab.file
        tab.stopFlush?()
        guard let page = tab.page, let file else {
            tab.page?.close()
            tab.provider?.close()
            // No page saves the edits: a close drops them, as one without saving does; a discard keeps them.
            if let file { settleDiscard(key, file: file) }
            return
        }
        // The page saves pending edits on `cmux.<page>.flush`; it stays alive (off screen) until it
        // answers. Past the timeout the page closes, which fails the pending call. A document no
        // other tab shows then leaves the quit hook; edits that did not save are dropped with it
        // (a close without saving removes the draft). A discarded tab keeps them for its next page.
        // The call goes through the page's router (main-actor isolated, so Sendable); the page view is not
        // Sendable and only the main-actor teardown holds it.
        let clock = clock, timeout = Self.flushTimeout, provider = tab.provider, op = kind.op("flush"), documents = documents,
            holder = holder(key), router = page.router
        // Each closure is assigned on its own: in a `?:` the literals get no @Sendable from the
        // annotation, so they would be non-Sendable values converted afterwards.
        let finish: @MainActor @Sendable () -> Void
        if closing {
            finish = { documents.release(file, holder: holder) }
        } else {
            finish = { [weak self] in self?.settleDiscard(key, file: file) }
        }
        let id = UUID()
        // The page's answer or the timeout, whichever comes first (a flexible, no-sooner request deadline); closing
        // the page then fails a call still pending. The teardown is a reply with no tab: the tab closed or was
        // discarded, and its page goes whether or not anything shows. It leaves `flushing` when it ran.
        flushing[id] = replies.reply(for: nil) {
            _ = await Deadline(timeout, clock: clock).value("files.flush") { try? await router.callPage(op, params: .object([:])) }
        } apply: { [weak self] _ in
            page.close()
            provider?.close()
            finish()
            self?.flushing[id] = nil
        }
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// How long a page may take to say what it shows before its discard goes on without it.
    static let viewStateTimeout: Duration = .seconds(1)

    func discardPolicy(for key: String) -> ContentDiscardPolicy { kind.discardPolicy }

    /// A tab whose page holds edits not on disk keeps its page at any pressure (Chrome's `kUserEdits`,
    /// cannot_discard_reason.h): its page said so, or its file's shared quit document is unsaved.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        guard let tab = tabs[key] else { return [] }
        let unsaved = tab.editsUnsaved || file(key).flatMap { documents.existing($0) }?.hasUnsavedChanges == true
        return unsaved ? [.unsavedEdits] : []
    }

    /// Asks the page `cmux.<page>.viewState`: `{dirty, view}`. The page reports a coalesced edit first
    /// and says whether it holds edits not on disk, so the discarder's second look at
    /// ``keepReasons(for:)`` sees them. A page that does not answer in time loses its place, never its text.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let page = tabs[key]?.page else { return ContentViewState() }
        let op = kind.op("viewState")
        let answer = await PageAnswerDeadline(Self.viewStateTimeout, clock: clock).answer {
            try await page.router.callPage(op, params: .object([:]))
        }
        guard let answer, tabs[key]?.page === page else { return ContentViewState() }
        if let dirty = answer["dirty"]?.boolValue { tabs[key]?.editsUnsaved = dirty }
        guard let view = answer["view"], view != .null else { return ContentViewState() }
        return ContentViewState(page: view)
    }

    /// The page gets its state in its first config (``makeView(for:in:)``), not from its view.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {}

    func willRemakeView(for key: String, with state: ContentViewState) {
        tabs[key]?.viewState = state.page
    }

    /// Tab `key`'s page goes; the tab keeps its file and route, what its page could open and save
    /// (a discard grants nothing), and the editor's cursor. Edits still not on disk once the page
    /// saved what it could stay in the quit hook for the next page, as a recovered draft.
    func viewDiscarded(_ key: String) {
        guard var tab = tabs[key] else { return }
        let gone = tab
        tab.access = tab.provider?.access ?? tab.access
        tab.reveal = tab.provider?.reveal ?? tab.reveal
        tab.stopFlush = nil
        tab.page = nil
        tab.provider = nil
        tab.host = nil
        tab.bar = nil
        tabs[key] = tab
        letPageGo(gone, key: key, closing: false)
    }

    /// The text of `file`'s quit document when it has edits not on disk: a discarded tab's draft.
    func unsavedText(of file: URL?) -> String? {
        guard let document = file.flatMap({ documents.existing($0) }), document.hasUnsavedChanges else { return nil }
        return document.latestText
    }

    /// A save of `url` wrote what its pages showed: their tabs hold no edits unless its document still does.
    func savedEdits(of url: URL) {
        let unsaved = documents.existing(url)?.hasUnsavedChanges ?? false
        for key in tabs.keys where file(key) == url { tabs[key]?.editsUnsaved = unsaved }
    }

    /// Tab `key`'s page closed: a discarded tab keeps a document with edits not on disk for its next
    /// page; otherwise, or once the tab closed, the tab lets it go. A tab shown again holds it anew.
    private func settleDiscard(_ key: String, file: URL) {
        guard tabs[key]?.page == nil else { return }
        if tabs[key] != nil, documents.existing(file)?.hasUnsavedChanges == true { return }
        documents.release(file, holder: holder(key))
    }

    /// App quit: closes every tab now.
    func terminate() {
        for tab in tabs.values {
            tab.page?.close()
            tab.provider?.close()
        }
        tabs.removeAll()
        look.stop()
    }
}
