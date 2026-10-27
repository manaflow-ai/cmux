import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextCompatAppKit
import CmuxNextHistory
import CmuxNextIcons
import CmuxNextPages
import Foundation
import Observation

/// The `cmux://history` page in a browser tab (plans/cmux-next/history.md
/// 5.1): a native view, no engine. Navigating it to a web address asks the
/// host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class HistoryPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.history, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: HistoryPageModel
    @ObservationIgnored let contentView: NSView
    /// The React page (Debug Settings `history.surface = web`; react-pages.md H1b), else nil.
    @ObservationIgnored let webPage: PageWebView?
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    /// The scroll position a hibernation saved, for the rebuilt page's first show.
    @ObservationIgnored let scrollRestore = BrowserAppPageScroll()

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: any HistoryPageSource,
         webPage: PageWebView? = nil) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: HistoryPageAddress.url, title: HistoryPageStrings.title)
        state.phase = .finished
        self.state = state
        model = HistoryPageModel(source: source)
        self.webPage = webPage
        if let webPage {
            contentView = webPage
        } else {
            contentView = HistoryPageHostView(model: model)
            model.reload()
        }
    }

    func load(_ url: URL) {
        if HistoryPageAddress.matches(url) { return reload() }
        onNavigate?(url)
    }

    func reload() {
        if let webPage { return webPage.reload() }
        model.reload()
    }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        if let webPage { return webPage.focusPage() }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        // The React page stays current from the owner's change events; the native one re-reads.
        if visible, webPage == nil { model.reload() }
        if visible { showSavedScroll() } else { scrollRestore.pageDidHide() }
    }

    func snapshot() async throws -> CGImage {
        // A hidden web view draws nothing into an AppKit cache: its engine pictures it.
        if let webPage {
            guard let image = await webPage.snapshot()?.bestCGImage else {
                throw BrowserTabError.snapshotUnavailable
            }
            return image
        }
        // A hidden page's SwiftUI is out of the window (feature visibilityGatedHosting): this draws it too.
        guard let image = contentView.cachedDisplayImage() else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        if let webPage {
            webPage.send(command: "find", arguments: ["text": .string(text)])
            return .none
        }
        model.text = text
        return .none
    }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {
        scrollRestore.cancel()
        webPage?.close()
    }
}

/// Hibernates as a web page does (`memoryDiscardPageTabs`): the native page's search, selection
/// and the scroll of its list go with the tab. The React page keeps its search in its document,
/// which no request reads, so it does not hibernate.
extension HistoryPageTab: BrowserAppPage {
    var pageAddress: URL { state.url ?? HistoryPageAddress.url }
    var supportsHibernation: Bool { webPage == nil }
    var drawsInFirstFrame: Bool { webPage == nil }

    func saveViewState() async -> BrowserAppPageState {
        BrowserAppPageState(url: pageAddress, scroll: scrollRestore.position(of: listScrollView), search: model.text,
                            selection: model.selection)
    }

    func restoreViewState(_ saved: BrowserAppPageState) {
        if let search = saved.search { model.text = search }
        model.selection = saved.selection
        scrollRestore.restore(saved.scroll)
    }

    /// The page's one list: its entries.
    private var listScrollView: NSScrollView? { BrowserAppPageScroll.listScrollView(in: contentView) }

    /// A saved scroll goes back once the list holds it; the entries load after the show.
    private func showSavedScroll() {
        scrollRestore.pageDidShow(list: { [weak self] in self?.listScrollView }, hasRows: { [model] in !model.groups.isEmpty })
    }
}

enum HistoryPageStrings {
    static var title: String { String(localized: "history.page.tabTitle", defaultValue: "History", table: "History", bundle: .module) }
}
