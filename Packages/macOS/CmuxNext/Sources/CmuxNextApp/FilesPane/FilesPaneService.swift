import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextFiles
import CmuxNextFilesUI
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
    }

    private weak var services: AppServices?
    private var tabs: [String: Tab] = [:]
    private let icons = FileIconProvider()
    /// Favorites and Locations, shared by every Files tab (the composition root picks `.standard`).
    private let sidebar = SidebarModel(home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    private var volumeWatch: [Task<Void, Never>] = []
    private var titleWatch: [String: Task<Void, Never>] = [:]
    /// The folder the next new tab opens on (``open(folder:focus:)``); home when nil.
    private var pendingFolder: URL?

    init(services: AppServices) {
        self.services = services
        let sidebar = self.sidebar
        volumeWatch = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                       NSWorkspace.didRenameVolumeNotification].map { name in
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
        guard let folder = tabs[key]?.model.folder else { return title }
        return folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
    }

    func history(for key: String) -> (any PageHistory)? { tabs[key]?.history }

    func route(for key: String) -> String? { tabs[key]?.model.folder.path }

    func restore(_ route: String, for key: String) {
        guard tabs[key] == nil, route.hasPrefix("/") else { return }
        tabs[key] = makeTab(URL(fileURLWithPath: route, isDirectory: true))
    }

    /// Opens a new Files tab on `folder` (default: home) after the active
    /// window's focused tab; `focus` false for automation (no focus change).
    func open(folder: URL? = nil, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        pendingFolder = folder
        guard services.pages.openNew(.filesPane, in: window, focus: focus) != nil else {
            pendingFolder = nil
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    private func makeTab(_ folder: URL) -> Tab {
        let model = FileBrowserModel(folder: folder, files: FileOperator(namer: FileNamer(copyWord: FilesPaneView.copyWord,
                                                                                   aliasWord: FilesPaneView.aliasWord)))
        return Tab(model: model, view: nil, history: FilesPaneHistory(model: model))
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        var tab = tabs[key] ?? makeTab(pendingFolder ?? FileManager.default.homeDirectoryForCurrentUser)
        pendingFolder = nil
        let view = FilesPaneView(model: tab.model, sidebar: sidebar, icons: icons) { [weak self] url in self?.openFile(url, from: key) }
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
        tabs.removeValue(forKey: key)?.view?.stop()
    }

    /// Text and code open in cmux's viewers beside the pane; anything else in its default app.
    private func openFile(_ url: URL, from key: String) {
        guard let services else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || url.pathExtension.isEmpty,
           services.viewers.openFile(url, in: services.paneController(showingTab: key), userChose: true) == nil {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
