import AppKit
import CmuxNextBrowser
import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextIcons
import CmuxNextScreenshots
import Foundation
import Observation

/// The `cmux://screenshots` page in a browser tab: the native Screenshots
/// pane, no engine (like ``AgentActivityPageTab``). The tab record persists
/// with the workspace, so the pane stays open across relaunches. Navigating
/// it to a web address asks the host (`onNavigate`) to turn the tab into a
/// real page.
@MainActor
@Observable
final class ScreenshotsPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.sitePermissionImages, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: ScreenshotsModel
    @ObservationIgnored let view: ScreenshotsView
    var contentView: NSView { view }
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    /// Runs when the tab closes (the service stops following settings for it).
    @ObservationIgnored var onClose: (() -> Void)?
    /// The scroll position a hibernation saved, for the rebuilt page's first show.
    @ObservationIgnored let scrollRestore = BrowserAppPageScroll()

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, model: ScreenshotsModel, cache: ThumbnailCache,
         workspace: any ScreenshotsWorkspace, files: any FileOperating) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: ScreenshotsPageAddress.url, title: ScreenshotsPageAddress.title)
        state.phase = .finished
        self.state = state
        self.model = model
        view = ScreenshotsView(model: model, cache: cache, workspace: workspace, files: files)
    }

    func load(_ url: URL) {
        if ScreenshotsPageAddress.matches(url) { return }
        onNavigate?(url)
    }

    func reload() {
        // task-owner: one relist the page's model owns; it ends when every folder is listed
        // main-hop-allow: Reload starts the model's own main-actor rescans (ScreenshotsModel.refresh schedules each folder's read, which lists off main); this task only awaits them
        Task { [model] in await model.refresh() }
    }

    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, view.window != nil else { return }
        view.focus()
    }

    func setContentVisible(_ visible: Bool) {
        view.isHidden = !visible
        if visible { showSavedScroll() } else { scrollRestore.pageDidHide() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BrowserTabError.snapshotUnavailable }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }

    /// Find (Cmd-F) filters the grid by file name, as the pane's search field does.
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        model.query = text
        return .none
    }

    func clearFind() { model.query = "" }
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}

    func close() {
        scrollRestore.cancel()
        model.stop()
        onClose?()
    }
}

/// Hibernates as a web page does (`memoryDiscardPageTabs`): the shown folder, the file name filter
/// and the grid's scroll go with the tab; its watches and reads stop with `close()`.
extension ScreenshotsPageTab: BrowserAppPage {
    var pageAddress: URL { state.url ?? ScreenshotsPageAddress.url }
    var drawsInFirstFrame: Bool { true }

    func saveViewState() async -> BrowserAppPageState {
        BrowserAppPageState(url: pageAddress, scroll: scrollRestore.position(of: view.grid.tilesScrollView), search: model.query,
                            selection: model.selectedSourceID)
    }

    func restoreViewState(_ saved: BrowserAppPageState) {
        if let search = saved.search { model.query = search }
        model.selectedSourceID = saved.selection
        scrollRestore.restore(saved.scroll)
    }

    /// A saved scroll goes back once the grid holds it; the files are listed after the show.
    private func showSavedScroll() {
        scrollRestore.pageDidShow(list: { [weak self] in self?.view.grid.tilesScrollView }, hasRows: { [model] in !model.visibleItems.isEmpty })
    }
}
