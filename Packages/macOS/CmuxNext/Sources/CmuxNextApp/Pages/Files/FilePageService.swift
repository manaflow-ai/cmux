import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSettings
import Foundation

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
        var page: PageWebView?
        var provider: FilePageProvider?
        var host: FilePageTabHost?
    }

    let kind: FilePageKind
    private unowned let services: AppServices
    private let clock: any Clock<Duration>
    private let images: any RemoteImageFetching
    private var tabs: [String: Tab] = [:]
    private(set) lazy var look = FilePageLook(kind: kind, services: services)
    /// Tabs whose pages are saving their last edits after the tab closed.
    private(set) var flushing: [Task<Void, Never>] = []

    /// The file pages draw at the display's full rate, as the diff and agent pages do.
    static let engineOptions = PageEngineOptions(fullFrameRate: true)
    /// How long a closed editor tab's page may take to save its pending edits.
    static let flushTimeout: Duration = .seconds(3)

    init(services: AppServices, kind: FilePageKind, clock: any Clock<Duration> = ContinuousClock(),
         images: any RemoteImageFetching = GuardedRemoteImages()) {
        self.services = services
        self.kind = kind
        self.clock = clock
        self.images = images
    }

    var page: InternalPageID { kind.page }
    var title: String { kind.title }
    var symbol: String { kind.symbol }

    func title(for key: String) -> String { tabs[key]?.file?.lastPathComponent ?? title }

    var openKeys: [String] { tabs.keys.sorted() }

    func pageView(_ key: String) -> PageWebView? { tabs[key]?.page }

    func provider(_ key: String) -> FilePageProvider? { tabs[key]?.provider }

    /// The file tab `key` shows, nil for the empty state or another tab.
    func file(_ key: String) -> URL? { tabs[key]?.provider?.file ?? tabs[key]?.file }

    /// Opens `file` in a tab after `pane`'s selected tab, or selects the tab of `pane`'s window that
    /// already shows it. A user run (`focus`) selects and focuses it.
    @discardableResult
    func open(_ file: URL, in pane: PaneController, focus: Bool) -> String {
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        services.viewers.recents.record(real, as: kind.recents)
        return show(in: pane, focus: focus, Tab(file: real)) { [unowned self] key in self.file(key) == real }
    }

    /// Opens (or selects) the window's empty tab of this page.
    @discardableResult
    func openEmpty(in pane: PaneController, focus: Bool) -> String {
        show(in: pane, focus: focus, Tab(file: nil)) { [unowned self] key in self.file(key) == nil }
    }

    private func show(in pane: PaneController, focus: Bool, _ tab: Tab, matching: (String) -> Bool) -> String {
        let window = services.windowController(showing: pane)
        for candidate in window?.content?.panes.values.map({ $0 }) ?? [pane] {
            if let shown = services.pages.tabIDs(in: candidate.paneKey).first(where: { tabs[$0] != nil && matching($0) }) {
                if focus { reveal(shown, in: candidate) }
                return shown
            }
        }
        let key = LocalPageTab.makeKey(kind.page)
        tabs[key] = tab
        services.pages.open(kind.page, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: window, key: key)
        pane.apply(pane.snapshot())
        if focus { reveal(key, in: pane) }
        return key
    }

    private func reveal(_ key: String, in pane: PaneController) {
        pane.select(StripTabID(key))
        pane.focusContent()
    }

    /// Tab `key` now shows `url` (an open in the page): retitle it.
    fileprivate func opened(_ url: URL, in key: String) {
        tabs[key]?.file = url
        if let pane = services.paneController(showingTab: key) { pane.apply(pane.snapshot()) }
    }

    fileprivate func pane(of key: String) -> PaneController? {
        services.paneController(showingTab: key) ?? services.windows.active?.focusedPane
    }

    // MARK: Host services for the tabs

    /// Every terminal folder of every window (diff-host.md: the workspace roots).
    var roots: FileWorkspaceRoots {
        var folders: [String] = []
        for window in services.windows.controllers {
            for pane in window.content?.panes.values.map({ $0 }) ?? [] {
                for tab in pane.pane.tabs where tab.kind == .pty {
                    if let cwd = tab.cwd, !cwd.isEmpty { folders.append(cwd) }
                }
            }
        }
        return FileWorkspaceRoots(folders: folders)
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

    fileprivate func openExternal(_ url: URL, from key: String) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            if let pane = pane(of: key) { pane.newBrowserTab(url: url) } else { NSWorkspace.shared.open(url) }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func openFile(_ url: URL, from key: String) {
        services.viewers.openFile(url, in: pane(of: key), markdown: FilePageKind.isMarkdown(url))
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard var tab = tabs[key] else { return NSView() }
        let host = FilePageTabHost(service: self, key: key)
        let libraries = Bundle.main.resourceURL.map(PageDescriptor.markdownLibraries(inAppResources:))
        let provider = FilePageProvider(kind: kind, file: tab.file, host: host, clock: clock, libraries: libraries, images: images)
        let native = AppPageNativeProvider(services: services, page: kind.descriptor)
        let routes = [PageRoute(prefix: kind.namespace + ".", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: kind.descriptor, routes: routes, options: Self.engineOptions, surface: kind.surface,
                                     dynamicResources: kind == .markdown ? provider : nil) else {
            return NSView()
        }
        native.anchor = { [weak page] in page }
        page.onOpenExternal = { [weak self] url in self?.openExternal(url, from: key) }
        page.fileDrop = fileDrop(provider: provider, page: page, key: key)
        tab.page = page
        tab.provider = provider
        tab.host = host
        tabs[key] = tab
        return page
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
        guard let tab = tabs.removeValue(forKey: key) else { return }
        guard kind == .editor, let page = tab.page, tab.provider?.file != nil else {
            tab.page?.close()
            tab.provider?.close()
            return
        }
        // The editor saves pending edits on `cmux.editor.flush`; the page stays alive (off screen)
        // until it answers. Past the timeout the page closes, which fails the pending call.
        let clock = clock, provider = tab.provider, op = kind.op("flush")
        let flush = Task { @MainActor in
            let deadline = Task { @MainActor in
                do { try await clock.sleep(for: Self.flushTimeout) } catch { return } // wakeup-allow: bounded flush on tab close
                page.close()
            }
            _ = try? await page.router.callPage(op, params: .object([:]))
            deadline.cancel()
            page.close()
            provider?.close()
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
    func setPreference(key: String, value: JSONValue) async throws { try await service?.look.setPreference(key: key, value: value) }
    func opened(_ url: URL) { service?.opened(url, in: key) }
    func openExternal(_ url: URL) { service?.openExternal(url, from: key) }
    func openFile(_ url: URL) { service?.openFile(url, from: key) }
}

extension FilePageService {
    fileprivate func servicesRecord(_ url: URL) {
        services.viewers.recents.record(url, as: kind.recents)
    }
}
