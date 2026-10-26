import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDesign
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
    private struct Tab {
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
    }

    let kind: FilePageKind
    // crash-allow: AppServices owns this service for the app's whole life (ViewerService's lazy page services), so it outlives it.
    unowned let services: AppServices
    private let clock: any Clock<Duration>
    private let images: any RemoteImageFetching
    private var tabs: [String: Tab] = [:]
    /// Markdown table column widths between opens (the file's extended attribute, then an app-side copy).
    private let tableWidths: (any MarkdownTableWidthStoring)?
    /// Where the markdown tabs keep viewer comments (viewer-comments-DESIGN.md "Comments in the viewer").
    private let comments: (any MarkdownCommentStoring)?
    private(set) lazy var look = FilePageLook(kind: kind, settings: { [weak services] in services?.settings })
    /// The documents of the R96 quit hook (one per file, shared with the other file page).
    let documents: FileQuitDocuments
    /// Files whose draft is over the store's limit and that already said so.
    private var warnedTooLarge: Set<String> = []
    /// Tabs whose pages are saving their last edits after the tab closed.
    private(set) var flushing: [Task<Void, Never>] = []
    /// The local live links of the Markdown Share menu, started on the first link.
    private(set) lazy var liveShare = MarkdownLiveShareServer(clock: clock, work: services.work)

    /// The file pages draw at the display's full rate, as the diff and agent pages do.
    static let engineOptions = PageEngineOptions(fullFrameRate: true)
    /// How long a closed editor tab's page may take to save its pending edits.
    static let flushTimeout: Duration = .seconds(3)

    init(services: AppServices, kind: FilePageKind, clock: any Clock<Duration> = ContinuousClock(),
         images: any RemoteImageFetching = GuardedRemoteImages(), documents: FileQuitDocuments? = nil,
         tableWidths: (any MarkdownTableWidthStoring)? = nil) {
        self.services = services
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
        self.images = images
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

    /// `controller`'s focused pane shows one of this page's tabs, read only (the config its
    /// provider last served said so): `markdownReadOnlyFocused` (K1).
    func showsReadOnly(focusedIn controller: WindowController) -> Bool {
        services.keyRouter.focusedPage(in: controller).map { page in tabs.values.contains { $0.page === page && $0.provider?.showsReadOnly == true } } ?? false
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
    private func holder(_ key: String) -> String { kind.namespace + ":" + key }

    // MARK: Quit hook (R96)

    fileprivate func edited(_ url: URL, text: String, baseHash: String?, writable: Bool, from key: String) -> RecoveryDraftAcceptance {
        guard let document = documents.document(for: url, holder: holder(key), writable: { [weak self] in self?.tabs[key]?.provider?.isWritable ?? writable }) else {
            return .invalidID
        }
        if tabs[key]?.stopFlush == nil, let page = tabs[key]?.page {
            let op = kind.op("flush")
            tabs[key]?.stopFlush = document.addFlusher { [weak page] in
                guard let page, let answer = try? await page.router.callPage(op, params: .object([:])) else { return true }
                return answer["dirty"]?.boolValue ?? true
            }
        }
        let accepted = document.edited(text: text, baseHash: baseHash)
        if accepted == .tooLarge, warnedTooLarge.insert(url.path).inserted, let window = tabs[key]?.page?.window {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "file-recovery:\(url.path)", message: FilePageStrings.noRecovery(url.lastPathComponent),
                                                     duration: .seconds(8)), in: window)
        }
        return accepted
    }

    fileprivate func saved(_ url: URL, hash: String) {
        documents.existing(url)?.saved(hash: hash)
        // A save can change the file's git state (clean to modified).
        for tab in tabs.values where tab.provider?.file == url { tab.bar?.refresh() }
    }

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
        pane.select(services.pages.stripID(showing: key, in: pane) ?? StripTabID(key))
        pane.focusContent()
    }

    /// Tab `key`'s page history moved: its omnibar's Back and Forward follow.
    fileprivate func historyChanged(canBack: Bool, canForward: Bool, in key: String) {
        tabs[key]?.bar?.setHistory(canBack: canBack, canForward: canForward)
    }

    /// Tab `key` now shows `url` (an open in the page): retitle it.
    fileprivate func opened(_ url: URL, in key: String) {
        if let previous = tabs[key]?.file, previous != url { left(previous, tab: key) }
        tabs[key]?.file = url
        tabs[key]?.bar?.show(url)
        if let pane = services.paneController(showingTab: key) { pane.apply(pane.snapshot()) }
    }

    fileprivate func pane(of key: String) -> PaneController? {
        services.paneController(showingTab: key) ?? services.windows.active?.focusedPane
    }

    // MARK: Host services for the tabs

    /// Every terminal folder of every window (diff-host.md: the workspace roots).
    var roots: FileWorkspaceRoots { Self.userChosenRoots(services) }

    /// Folders the user chose as roots (the `files.roots` setting); never home, `/` or a folder the
    /// host infers (a terminal's working directory).
    static func userChosenRoots(_ services: AppServices) -> FileWorkspaceRoots {
        let folders = services.settings?.fileRoot["files"]?["roots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return FileWorkspaceRoots(folders: folders.map { ($0 as NSString).expandingTildeInPath })
    }

    /// The "Open <path>?" sheet for links outside a granted folder: one at a time, after a real
    /// user gesture on a file page.
    private(set) lazy var openConfirmation = FileOpenConfirmation()

    fileprivate func isRecent(_ path: String) -> Bool {
        let recents = services.viewers.recents
        return recents.paths(.markdown).contains(path) || recents.paths(.file).contains(path)
    }

    fileprivate func confirmOpen(_ url: URL, userGesture: Bool, from key: String) async -> Bool {
        let page = tabs[key]?.page
        return await openConfirmation.confirm(url, userGesture: userGesture, gestureEvent: page?.lastUserEventUptime, anchor: page)
    }

    fileprivate func recents() -> JSONValue {
        JSONValue(foundation: services.viewers.recents.hostOpValue(kind.recents)) ?? ["items": []]
    }

    fileprivate func chooseFile(start: URL?, for key: String) async -> URL? {
        var start = start
        if start == nil, let newest = services.viewers.recents.paths(kind.recents).first {
            start = URL(fileURLWithPath: newest).deletingLastPathComponent()
        }
        if kind == .markdown { return await services.viewers.chooseMarkdownFile(start: start?.path).map { URL(fileURLWithPath: $0) } }
        let options = CmuxPicker.OpenOptions(choose: .files, startDirectory: start, recents: [.file, .markdown])
        return await services.viewers.picker.open(options, over: tabs[key]?.page?.window)?.first
    }

    /// A web link clicked in the page: the link setting (``LinkRouter``, cmux browser or the default
    /// browser) and, in cmux, beside the page's pane (``LinkOpener``).
    fileprivate func openExternal(_ url: URL, from key: String) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard LinkRouter.shared.target(for: url) == .cmuxBrowser else { return LinkRouter.shared.open(url, in: .system) }
            if let pane = pane(of: key) { services.linkOpener.openWeb(url, from: pane, background: false) } else { NSWorkspace.shared.openInBackground(url) }
        default:
            NSWorkspace.shared.openInBackground(url)
        }
    }

    fileprivate func openAppLink(_ url: URL) -> Bool {
        CmuxAppLinks.open(url, services: services)
    }

    /// A file link clicked in the page opens beside the page's pane (``LinkOpener``).
    fileprivate func openFile(_ url: URL, from key: String) {
        services.linkOpener.openFile(url, from: pane(of: key), markdown: FilePageKind.isMarkdown(url))
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // A store tab with no route (an empty tab, an older daemon) shows the empty state.
        var tab = tabs[key] ?? Tab(file: nil)
        let host = FilePageTabHost(service: self, key: key)
        let libraries = Bundle.main.resourceURL.map(PageDescriptor.markdownLibraries(inAppResources:))
        let provider = FilePageProvider(kind: kind, file: tab.file, userChose: tab.userChose, readOnly: tab.readOnly, host: host, clock: clock,
                                        libraries: libraries, images: images, tableWidths: tableWidths,
                                        comments: comments)
        provider.recoveredText = tab.recoveredText
        provider.reveal = tab.reveal
        tab.reveal = nil
        let native = AppPageNativeProvider(services: services, page: kind.descriptor)
        let routes = [PageRoute(prefix: kind.namespace + ".", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: kind.descriptor, routes: routes, options: Self.engineOptions, surface: kind.surface,
                                     dynamicResources: kind == .markdown ? provider : nil) else {
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
        let bar = MarkdownOmnibarBar(suggestionEngine: services.cache.suggestionEngine, actions: actions)
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
        // task-owner: one open of the typed file; ends when the tab shows it or refuses it
        Task {
            guard (try? await provider.open(url)) != nil else { return NSSound.beep() }
            page.reload()
        }
    }

    /// Finder drops (WebKit hides their paths from the page): the empty tab opens the dropped file
    /// in place; a tab with a file sends it through the file routing to its own tab.
    private func fileDrop(provider: FilePageProvider, page: PageWebView, key: String) -> PageFileDrop {
        PageFileDrop(accepts: { url in url.isFileURL && !url.hasDirectoryPath }, open: { [weak self, weak provider, weak page] url in
            guard let self, let provider else { return }
            guard provider.isPicking, provider.kind.accepts(url) else { return self.openFile(url, from: key) }
            // task-owner: one open of the dropped file; ends when the tab shows it or refuses it
            Task {
                guard (try? await provider.open(url)) != nil else { return NSSound.beep() }
                page?.reload()
            }
        })
    }

    func tabClosed(_ key: String) {
        guard let tab = tabs[key] else { return }
        let file = tab.provider?.file ?? tab.file
        tab.stopFlush?()
        tabs[key] = nil
        guard let page = tab.page, let file else {
            tab.page?.close()
            tab.provider?.close()
            return
        }
        // The page saves pending edits on `cmux.<page>.flush`; it stays alive (off screen) until it
        // answers. Past the timeout the page closes, which fails the pending call. A document no
        // other tab shows then leaves the quit hook; edits that did not save are dropped with it
        // (a close without saving removes the draft).
        let clock = clock, provider = tab.provider, op = kind.op("flush"), documents = documents, holder = holder(key)
        let flush = Task { @MainActor in
            let deadline = Task { @MainActor in
                do { try await clock.sleep(for: Self.flushTimeout) } catch { return } // wakeup-allow: bounded flush on tab close
                page.close()
            }
            _ = try? await page.router.callPage(op, params: .object([:]))
            deadline.cancel()
            page.close()
            provider?.close()
            documents.release(file, holder: holder)
        }
        flushing.append(flush)
        // task-owner: drops the finished flush from `flushing`
        Task { [weak self] in
            await flush.value
            self?.flushing.removeAll { $0 == flush }
        }
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

/// One tab's ``FilePageHosting``: the service, scoped to that tab.
final class FilePageTabHost: FilePageHosting {
    private weak var service: FilePageService?
    private let key: String

    init(service: FilePageService, key: String) {
        self.service = service
        self.key = key
    }

    var roots: FileWorkspaceRoots { service?.roots ?? FileWorkspaceRoots(folders: []) }
    var remoteImages: Bool { service?.look.remoteImages ?? false }
    func recents() -> JSONValue { service?.recents() ?? ["items": []] }
    func record(_ url: URL) {
        guard let service else { return }
        service.servicesRecord(url)
    }
    func chooseFile(start: URL?) async -> URL? { await service?.chooseFile(start: start, for: key) }
    func look() -> JSONValue { service?.look.current() ?? .object([:]) }
    func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { service?.look.listen(onLook) ?? {} }
    func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {
        try await service?.look.setPreference(key: key, value: value, by: writer)
    }
    func opened(_ url: URL) { service?.opened(url, in: key) }
    func openExternal(_ url: URL) { service?.openExternal(url, from: key) }
    func openFile(_ url: URL) { service?.openFile(url, from: key) }
    func openAppLink(_ url: URL) -> Bool { service?.openAppLink(url) ?? false }
    func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance {
        service?.edited(url, text: text, baseHash: baseHash, writable: writable, from: key) ?? .kept
    }
    func saved(_ url: URL, hash: String) { service?.saved(url, hash: hash) }
    var showsOmnibar: Bool { service?.kind == .markdown }
    func historyChanged(canBack: Bool, canForward: Bool) { service?.historyChanged(canBack: canBack, canForward: canForward, in: key) }
    func isRecent(_ path: String) -> Bool { service?.isRecent(path) ?? false }
    func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { await service?.confirmOpen(url, userGesture: userGesture, from: key) ?? false }
}

extension FilePageService {
    fileprivate func servicesRecord(_ url: URL) {
        services.viewers.recents.record(url, as: kind.recents)
    }
}
