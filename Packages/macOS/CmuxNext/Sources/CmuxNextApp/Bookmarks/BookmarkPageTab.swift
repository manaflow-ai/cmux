import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextIcons
import Foundation
import Observation

/// The `cmux://bookmarks` manager in a browser tab: a native view, no engine
/// (works in builds without Chromium). Navigating it to a web address asks
/// the host (`onNavigate`) to turn the tab into a real page.
@Observable
final class BookmarkPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.bookmarkManager, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: BookmarkManagerModel
    @ObservationIgnored let source: BookmarkManagerSourceAdapter
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    /// The scroll position a hibernation saved, for the rebuilt page's first show.
    @ObservationIgnored let scrollRestore = BrowserAppPageScroll()

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: BookmarkManagerSourceAdapter) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: BookmarkPageAddress.url, title: BookmarkStrings.pageTitle)
        state.phase = .finished
        self.state = state
        self.source = source
        model = BookmarkManagerModel(source: source)
        contentView = BookmarkManagerHostView(model: model)
    }

    func load(_ url: URL) {
        if BookmarkPageAddress.matches(url) { return model.reload() }
        onNavigate?(url)
    }

    func reload() { model.reload() }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { model.reload() }
        if visible { showSavedScroll() } else { scrollRestore.pageDidHide() }
    }

    func snapshot() async throws -> CGImage {
        // A hidden page's SwiftUI is out of the window (feature visibilityGatedHosting): this draws it too.
        guard let image = contentView.cachedDisplayImage() else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        model.query = text
        return .none
    }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() { scrollRestore.cancel() }
}

/// Hibernates as a web page does (`memoryDiscardPageTabs`): the shown folder, the search and the
/// scroll of the bookmark list go with the tab.
extension BookmarkPageTab: BrowserAppPage {
    var pageAddress: URL { state.url ?? BookmarkPageAddress.url }
    var drawsInFirstFrame: Bool { true }

    func saveViewState() async -> BrowserAppPageState {
        BrowserAppPageState(url: pageAddress, scroll: scrollRestore.position(of: listScrollView), search: model.query,
                            selection: model.folder)
    }

    func restoreViewState(_ saved: BrowserAppPageState) {
        if let folder = saved.selection { model.folder = folder }
        if let search = saved.search { model.query = search }
        scrollRestore.restore(saved.scroll)
    }

    /// The bookmark list (a `List`), not the folder sidebar beside it (a `ScrollView`).
    private var listScrollView: NSScrollView? { BrowserAppPageScroll.listScrollView(in: contentView) }

    /// A saved scroll goes back once the list holds it.
    private func showSavedScroll() {
        scrollRestore.pageDidShow(list: { [weak self] in self?.listScrollView }, hasRows: { [model] in !model.rows.isEmpty })
    }
}
