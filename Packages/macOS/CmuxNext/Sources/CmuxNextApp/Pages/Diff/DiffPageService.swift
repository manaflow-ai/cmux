import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSettings

extension InternalPageID {
    /// The diff viewer (diff-host.md Q4: a pane tab in the workspace).
    nonisolated static let diff = InternalPageID(rawValue: "diff")
}

/// Why ``DiffPageService/open(folder:source:in:focus:)`` opened nothing.
nonisolated enum DiffOpenFailure: Error, Sendable, Equatable {
    /// The folder is in no git repository (or the session host cannot say).
    case notRepository
}

/// Owns the diff viewer tabs: `cmux-page://cmux.diff/` pages, one per tab, each
/// with its own provider, grant and patch source (``DiffPageProvider``,
/// ``DiffSessionGrant``, ``DiffPatchSource``).
///
/// Entry points: ``open(folder:source:in:focus:)`` opens the tab of a folder's
/// repository (the bound actions with the focused pane's folder, R89's picker
/// with a chosen one); ``openEmpty(in:focus:)`` opens the empty state, where
/// the page lists recents, asks for a folder (``DiffFolderChoosing``, the seam
/// R89's shared picker replaces) or takes a dropped one. Every open records
/// the repository in ``DiffRecents``.
final class DiffPageService: InternalPageProvider {
    private struct Tab {
        var repository: DiffRepository?
        var source: DiffOpenSource
        var page: PageWebView?
        var provider: DiffPageProvider?
        var host: DiffTabHost?
    }

    private unowned let services: AppServices
    /// Made on the first tab (tests pass their own).
    private lazy var runtime = DiffPageRuntime(git: services.agentGit)
    private lazy var recentsStore = DiffRecents(url: DiffRecents.standardURL(launch: services.environment.launch))
    /// Prefs (`diff.*` settings) and viewed marks (next to the recents), shared by every tab.
    private lazy var stores = DiffPageStores(prefs: SettingsDiffPrefs { [unowned services] in services.settings },
                                             viewed: DiffViewedFiles(url: DiffViewedFiles.standardURL(recents: recentsStore.url)))
    /// The diff page draws at the display's full rate (120 Hz), as the agent pane does, not
    /// WebKit's default nearest 60 fps.
    static let engineOptions = PageEngineOptions(fullFrameRate: true)
    /// The folder picker of `cmux.diff.chooseFolder`.
    var chooser: any DiffFolderChoosing = OpenPanelFolderChooser()
    private var tabs: [String: Tab] = [:]
    /// Teardowns still closing sessions (tests wait on them).
    private(set) var closing: [Task<Void, Never>] = []

    init(services: AppServices, runtime: DiffPageRuntime? = nil, recents: DiffRecents? = nil, stores: DiffPageStores? = nil) {
        self.services = services
        if let runtime { self.runtime = runtime }
        if let recents { recentsStore = recents }
        if let stores { self.stores = stores }
    }

    var page: InternalPageID { .diff }
    var title: String { DiffPageStrings.tabTitle }
    var symbol: String { "plusminus" }
    var recents: DiffRecents { recentsStore }

    func title(for key: String) -> String { tabs[key]?.repository?.name ?? title }

    /// Opens a diff tab for the repository `folder` is in, comparing `source`
    /// first, after `pane`'s selected tab, or selects the tab of `pane`'s
    /// window that already shows it. A user run (`focus`) selects and focuses
    /// it. Throws ``DiffOpenFailure/notRepository`` and opens nothing when the
    /// folder is in no repository.
    @discardableResult
    func open(folder: URL, source: DiffOpenSource = .default, in pane: PaneController,
              focus: Bool) async throws(DiffOpenFailure) -> String {
        guard let repository = await runtime.repository(at: folder) else { throw .notRepository }
        return open(repository: repository, source: source, in: pane, focus: focus)
    }

    /// ``open(folder:source:in:focus:)`` once the repository is known.
    @discardableResult
    func open(repository: DiffRepository, source: DiffOpenSource = .default, in pane: PaneController, focus: Bool) -> String {
        record(repository, source: source)
        return show(in: pane, focus: focus, Tab(repository: repository, source: source)) {
            $0.repository?.root == repository.root && $0.source == source
        }
    }

    /// Opens (or selects) the window's empty diff tab: recents, a folder
    /// picker and folder drops.
    @discardableResult
    func openEmpty(in pane: PaneController, focus: Bool) -> String {
        show(in: pane, focus: focus, Tab(repository: nil, source: .default)) { $0.repository == nil }
    }

    private func show(in pane: PaneController, focus: Bool, _ tab: Tab, matching: (Tab) -> Bool) -> String {
        let window = services.windowController(showing: pane)
        for candidate in window?.content?.panes.values.map({ $0 }) ?? [pane] {
            if let shown = services.pages.tabIDs(in: candidate.paneKey).first(where: { tabs[$0].map(matching) ?? false }) {
                if focus { reveal(shown, in: candidate) }
                return shown
            }
        }
        let key = LocalPageTab.makeKey(.diff)
        tabs[key] = tab
        services.pages.open(.diff, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: window, key: key)
        pane.apply(pane.snapshot())
        if focus { reveal(key, in: pane) }
        return key
    }

    private func reveal(_ key: String, in pane: PaneController) {
        pane.select(StripTabID(key))
        pane.focusContent()
    }

    private func record(_ repository: DiffRepository, source: DiffOpenSource) {
        let recents = recentsStore
        // task-owner: one ordered append to the recents file; DiffRecents chains its writes
        Task { await recents.record(repository, source: source) }
    }

    /// The diff page of `key`, nil for any other tab or before its view exists.
    func pageView(_ key: String) -> PageWebView? { tabs[key]?.page }

    func provider(_ key: String) -> DiffPageProvider? { tabs[key]?.provider }

    var openKeys: [String] { tabs.keys.sorted() }

    // MARK: Tab host

    fileprivate func repository(at folder: URL) async -> DiffRepository? { await runtime.repository(at: folder) }

    fileprivate func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
        runtime.prepare(repository: repository, source: source)
    }

    fileprivate func chooseFolder(start: URL?, for key: String) async -> URL? {
        var start = start
        if start == nil, let newest = await recentsStore.list().first {
            start = URL(fileURLWithPath: newest.path).deletingLastPathComponent()
        }
        return await chooser.chooseFolder(start: start, anchor: tabs[key]?.page?.window)
    }

    /// The tab `key` now shows `repository`: record it and retitle the tab.
    fileprivate func opened(_ repository: DiffRepository, source: DiffOpenSource, in key: String) {
        record(repository, source: source)
        tabs[key]?.repository = repository
        tabs[key]?.source = source
        if let pane = services.paneController(showingTab: key) { pane.apply(pane.snapshot()) }
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard var tab = tabs[key] else { return NSView() }
        let host = DiffTabHost(service: self, key: key)
        let ready = tab.repository.map { runtime.prepare(repository: $0, source: tab.source) }
        let provider = DiffPageProvider(ready: ready, sidecar: runtime.sidecar, languages: runtime.languages, host: host,
                                        stores: stores)
        let native = AppPageNativeProvider(services: services, page: .diff)
        let routes = [PageRoute(prefix: "cmux.diff.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .diff, routes: routes, options: Self.engineOptions, surface: .diff,
                                     dynamicResources: DiffPatchSource { [weak provider] in provider?.ready }) else {
            ready?.cancel()
            return NSView()
        }
        native.anchor = { [weak page] in page }
        page.fileDrop = Self.folderDrop(provider: provider, page: page)
        tab.page = page
        tab.provider = provider
        tab.host = host
        tabs[key] = tab
        return page
    }

    /// An empty diff tab opens a folder dropped from Finder (the page cannot
    /// read its path): a dropped file opens its folder. The page reloads to
    /// show the repository.
    static func folderDrop(provider: DiffPageProvider, page: PageWebView) -> PageFileDrop {
        PageFileDrop(accepts: { [weak provider] url in url.isFileURL && provider?.isPicking == true }, open: { [weak provider, weak page] url in
            let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            // task-owner: one open of the dropped folder; ends when the tab shows it or refuses it
            Task {
                guard let provider, (try? await provider.open(folder: folder, source: .default)) != nil else {
                    return NSSound.beep()
                }
                page?.reload()
            }
        })
    }

    func tabClosed(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        tab.page?.close()
        guard let provider = tab.provider else { return }
        let teardown = Task { await provider.close() }
        closing.append(teardown)
        // task-owner: drops the finished teardown from `closing`
        Task { [weak self] in
            await teardown.value
            self?.closing.removeAll { $0 == teardown }
        }
    }

    /// App quit: removes every tab's grant now (patches included). Sessions are
    /// not closed through the sidecar; the files they used go with the grant.
    func terminate() {
        for tab in tabs.values {
            tab.page?.close()
            tab.provider?.ready?.cancel()
        }
        tabs.removeAll()
        DiffPageRuntime.removeAllGrantsNow()
    }
}

/// One tab's ``DiffTabHosting``: the service, scoped to that tab.
final class DiffTabHost: DiffTabHosting {
    private weak var service: DiffPageService?
    private let key: String

    init(service: DiffPageService, key: String) {
        self.service = service
        self.key = key
    }

    func repository(at folder: URL) async -> DiffRepository? { await service?.repository(at: folder) }

    func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
        service?.prepare(repository, source: source)
            ?? Task { throw DiffTabFailure(title: repository.name, message: DiffPageStrings.unavailable) }
    }

    func recents() async -> JSONValue { await service?.recents.page() ?? ["items": .array([])] }

    func chooseFolder(start: URL?) async -> URL? { await service?.chooseFolder(start: start, for: key) }

    func opened(_ repository: DiffRepository, source: DiffOpenSource) {
        service?.opened(repository, source: source, in: key)
    }
}
