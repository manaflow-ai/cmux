import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextHibernation
import CmuxNextIcons
import UniformTypeIdentifiers

extension InternalPageID {
    /// The native Files pane (u2360; `files` is the chat's git tree page).
    nonisolated static let filesPane = InternalPageID(rawValue: "files-pane")
}

/// Owns the native Files pane tabs (plans/finder-parity/PARITY.md): one
/// ``FileBrowserModel`` and ``FilesPaneView`` per tab. Each `files.open` run
/// opens a new tab (Finder's Cmd+N), on the home folder. The tab's route is
/// its folder, so Reopen Closed and relaunch come back to it; Back and
/// Forward plug into page history.
@MainActor
final class FilesPaneService: InternalPageProvider {
    private struct Tab {
        var model: FileBrowserModel
        var view: FilesPaneView?
        var history: FilesPaneHistory
        /// The view was discarded and its folder watch stopped; the next view lists the folder again.
        var discarded = false
    }

    private weak var services: AppServices?
    private var tabs: [String: Tab] = [:]
    private let icons = FileIconProvider()
    /// Favorites and Locations, shared by every Files tab (the composition root picks `.standard`).
    private let sidebar = SidebarModel(home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    private var volumeWatch: [Task<Void, Never>] = []
    private var titleWatch: [String: Task<Void, Never>] = [:]
    /// What a new tab opens on.
    private struct OpenRequest {
        /// The folder (``open(folder:focus:)``); home when nil.
        var folder: URL?
        /// The item it selects (``reveal(_:focus:)``).
        var selection: URL?
    }

    /// What each open asked for, for the tab it opened.
    private let opens = PageOpenRequests<OpenRequest>()
    /// The shared file menu's Open as Text, Open With and Share rows for the pane's context menu.
    private lazy var fileMenu = FileActionsMenu(actions: .init(
        openInCmux: { [weak self] url in self?.services?.linkOpener.openFile(url, from: self?.services?.windows.active?.focusedPane) },
        revealInFiles: { [weak self] url in try? self?.reveal(url, focus: true) },
        openAsText: { [weak self] url in self?.services?.linkOpener.openFile(url, from: self?.services?.windows.active?.focusedPane, asText: true) }))

    init(services: AppServices) {
        self.services = services
        let sidebar = self.sidebar
        volumeWatch = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                       NSWorkspace.didRenameVolumeNotification].map { name in
            // task-owner: stored in volumeWatch; the service lives as long as the app
            Task { @MainActor in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) { sidebar.refreshLocations() }
            }
        }
    }

    var page: InternalPageID { .filesPane }
    var title: String { FilesPaneView.paneTitle }
    var symbol: String { "folder" }
    var icon: IconName? { .folder }

    func title(for key: String) -> String {
        guard let folder = tabs[key]?.model.folder ?? opens.kept(for: key)?.folder else { return title }
        return folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
    }

    func history(for key: String) -> (any PageHistory)? { tabs[key]?.history }

    func route(for key: String) -> String? { (tabs[key]?.model.folder ?? opens.kept(for: key)?.folder)?.path }

    func restore(_ route: String, for key: String) {
        guard tabs[key] == nil, route.hasPrefix("/") else { return }
        tabs[key] = makeTab(URL(fileURLWithPath: route, isDirectory: true))
    }

    /// Opens a new Files tab on `folder` (default: home) after the active
    /// window's focused tab; `focus` false for automation (no focus change).
    func open(folder: URL? = nil, focus: Bool) throws {
        try open(OpenRequest(folder: folder), focus: focus)
    }

    private func open(_ request: OpenRequest, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        guard opens.open(request, { services.pages.openNew(.filesPane, in: window, focus: focus) }) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    /// Opens a new Files tab on `item`'s folder with `item` selected (Reveal in cmux Files): beside
    /// a docked Home or chat, never in it. A folder opens on itself.
    func reveal(_ item: URL, focus: Bool) throws {
        let isFolder = FileOpenKind(url: item) == .folder
        try open(OpenRequest(folder: isFolder ? item : item.deletingLastPathComponent(), selection: isFolder ? nil : item), focus: focus)
    }

    private func makeTab(_ folder: URL) -> Tab {
        let model = FileBrowserModel(folder: folder, files: FileOperator(namer: FileNamer(copyWord: FilesPaneView.copyWord,
                                                                                   aliasWord: FilesPaneView.aliasWord)),
                                     memory: FolderViewMemory(defaults: .standard))
        return Tab(model: model, view: nil, history: FilesPaneHistory(model: model))
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // The running open's request is the new tab's: a tab it did not open has its model already.
        let request = opens.take(for: key) ?? (tabs[key] == nil ? opens.running : nil)
        var tab = tabs[key] ?? makeTab(request?.folder ?? FileManager.default.homeDirectoryForCurrentUser)
        if tab.discarded {
            // The discard stopped the folder watch: list the folder again (selection kept), which watches it again.
            tab.discarded = false
            let model = tab.model
            // task-owner: one listing of the tab's folder; the model's generation drops it when a newer one starts
            Task { await model.reload() }
        }
        if let selection = request?.selection {
            let model = tab.model
            // task-owner: one listing; ends when the item is selected
            Task { await model.open(selection.deletingLastPathComponent(), select: selection) }
        }
        let view = FilesPaneView(model: tab.model, sidebar: sidebar, icons: icons) { [weak self] url in self?.openFile(url, from: key) }
        view.fileMenu = fileMenu
        tab.view = view
        tabs[key] = tab
        let model = tab.model
        titleWatch[key] = Task { [weak self] in
            var last = model.folder
            for await folder in ObservationStream({ [model] in model.folder }) where folder != last {
                last = folder
                guard let self, let pane = self.services?.paneController(showingTab: key) else { continue }
                pane.apply(pane.snapshot())
            }
        }
        return view
    }

    func tabClosed(_ key: String) {
        titleWatch.removeValue(forKey: key)?.cancel()
        opens.forget(key)
        tabs.removeValue(forKey: key)?.view?.stop()
    }

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory-026)

    /// Ten minutes hidden, as Chrome's proactive discards (proactive_discarding_policy.cc). The
    /// view, its icons and its folder watch go; the model stays (folder, selection, sort, filter,
    /// layout and Back/Forward), so the next view shows the same place.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A Get Info panel the pane opened shows on its own while the tab is hidden: the discard would
    /// close it, so the pane stays while one is open. An inline rename ends when the view leaves its
    /// window, so nothing else in the view is unsaved.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        tabs[key]?.view?.showsInfoPanels == true ? [.openPanel] : []
    }

    /// The model keeps what the view showed (folder, selection, sort, filter, layout); the view
    /// keeps the list or icon layout's scroll, which the default (the first scroll view) would take
    /// from the sidebar.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        ContentViewState(scroll: (content as? FilesPaneView)?.contentScroll)
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        guard let scroll = state.scroll else { return }
        (content as? FilesPaneView)?.scrollContent(to: scroll)
    }

    func viewDiscarded(_ key: String) {
        titleWatch.removeValue(forKey: key)?.cancel()
        tabs[key]?.view?.stop()
        tabs[key]?.view = nil
        tabs[key]?.discarded = true
    }

    /// A double-clicked file opens in cmux when cmux shows its kind (``FileOpenKind``: Markdown,
    /// web pages, images, PDF, media, text, code) beside the pane; apps and documents cmux cannot
    /// show (Office files, archives) open in their default app, as in Finder.
    private func openFile(_ url: URL, from key: String) {
        guard let services else { return }
        switch FileOpenKind(fileName: url.lastPathComponent, isDirectory: false, isPackage: false) {
        case .markdown, .web, .preview, .editor:
            let source = services.paneController(showingTab: key)
            if services.linkOpener.openFile(url, from: source) { return }
        case .folder, .app, .other:
            break
        }
        NSWorkspace.shared.openInBackground(url)
    }
}
