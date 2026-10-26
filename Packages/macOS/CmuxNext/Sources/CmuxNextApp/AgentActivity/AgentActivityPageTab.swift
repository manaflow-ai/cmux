import AppKit
import CmuxNextAgentActivity
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextIcons
import CmuxNextControl
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Observation

/// The `cmux://agent-activity` page in a browser tab: the Activity page on the
/// shared page host (``PageDescriptor/agentActivity``, Chromium or WebKit by
/// `browser.defaultEngine`), else the old WebKit view when the page host has no
/// root for it. Navigating it to a web address asks the host (`onNavigate`) to
/// turn the tab into a real page.
@MainActor
@Observable
final class AgentActivityPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.agentActivity, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: AgentActivityModel
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    /// The document scroll a hibernation saved, until the rebuilt document painted and ran it.
    @ObservationIgnored var savedScroll: BrowserAppPageState.Point?
    /// A woken page's last picture over its document until the document paints (`BrowserWakeStandIn`).
    @ObservationIgnored var standIn: NSView?
    /// Takes the picture away at the stand-in's cap when the document never painted.
    @ObservationIgnored let standInCap: MainDeadline

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: any AgentActivitySource, webUI: WebUIHost,
         deadlines: MainDeadlineScheduler) {
        self.id = id
        standInCap = MainDeadline(owner: "AgentActivityPageTab.standIn", workClass: .visible, scheduler: deadlines)
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: AgentActivityPageAddress.url, title: AgentActivityPaneStrings.title)
        state.phase = .finished
        self.state = state
        let model = AgentActivityModel(source: source)
        self.model = model
        let provider = AgentActivityPageProvider(requests: AgentActivityRequests(model: model, source: source))
        contentView = webUI.open(PageOpenRequest(descriptor: .agentActivity,
                                                 routes: [PageRoute(prefix: AgentActivityPageProvider.prefix, provider: provider)]))
            ?? AgentActivityHostView(model: model, source: source)
        model.start()
    }

    func load(_ url: URL) {
        if AgentActivityPageAddress.matches(url) { return }
        onNavigate?(url)
    }

    func reload() {}
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        if let page = contentView as? PageWebView { return page.focusPage() }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
    }

    func snapshot() async throws -> CGImage {
        // A hidden web view draws nothing into an AppKit cache: its engine pictures it.
        if let page = contentView as? PageWebView {
            guard let image = await page.snapshot()?.bestCGImage else {
                throw BrowserTabError.snapshotUnavailable
            }
            return image
        }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        model.filter = text
        return .none
    }
    func clearFind() { model.filter = "" }
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    /// Closed or discarded: the model's pushes stop (the host stops sending sessions and events),
    /// then the page goes.
    func close() {
        savedScroll = nil
        removeStandIn()
        model.stop()
        (contentView as? PageWebView)?.close()
    }
}

/// Hibernates as a web page does (`memoryDiscardPageTabs`): the filter and the selected session
/// (the model's, which the page reads when it starts) and the document's scroll go with the tab;
/// the rebuilt page starts a new model.
extension AgentActivityPageTab: BrowserAppPage {
    var pageAddress: URL { state.url ?? AgentActivityPageAddress.url }
    /// A web engine draws it once its document loads.
    var drawsInFirstFrame: Bool { false }

    func saveViewState() async -> BrowserAppPageState {
        var scroll = savedScroll
        if scroll == nil { scroll = await documentScroll() }
        return BrowserAppPageState(url: pageAddress, scroll: scroll, search: model.filter, selection: model.selectedSessionID)
    }

    func restoreViewState(_ saved: BrowserAppPageState) {
        if let search = saved.search { model.filter = search }
        if let session = saved.selection { model.select(session: session) }
        savedScroll = saved.scroll
        guard let scroll = saved.scroll, scroll.x.isFinite, scroll.y.isFinite, let page = contentView as? PageWebView else { return }
        // The document scrolls once it painted (WebKit and Chromium scroll a page in its renderer).
        page.whenPainted { [weak self, weak page] in
            guard let self, let page, self.savedScroll == scroll else { return }
            page.evaluate("window.scrollTo(\(scroll.x), \(scroll.y));")
            self.savedScroll = nil
        }
    }

    /// The document's scroll, read within 2 s; nil for the old WebKit view or a page that does not answer.
    private func documentScroll() async -> BrowserAppPageState.Point? {
        guard let page = contentView as? PageWebView else { return nil }
        let point = try? await ControlDeadline.shared.run(method: "pages.discard.scroll", deadline: .now + .seconds(2)) { @MainActor in
            await page.documentScroll()
        }
        return point.map { BrowserAppPageState.Point(x: Double($0.x), y: Double($0.y)) }
    }
}

/// A woken page's last frame over its rebuilt document until the document paints, at most `cap`,
/// as a woken web page's (`WebKitTab+WakeStandIn`). The old WebKit view has no paint signal and a
/// Chromium page draws in the engine's own view: those wakes count as uncovered.
extension AgentActivityPageTab: BrowserWakeStandIn {
    @discardableResult
    func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool {
        guard let page = contentView as? PageWebView, !page.showsChromium else { return false }
        removeStandIn()
        // Pixels already decoded cover the page from the swap's first frame.
        let view = decoded ? BrowserPictureView(decoded: picture) : BrowserPictureView(picture: { picture })
        view.frame = page.bounds
        view.autoresizingMask = [.width, .height]
        page.addSubview(view, positioned: .above, relativeTo: nil)
        standIn = view
        // The cap of a stand-in, not a poll; the paint or a close cancels it. It runs on the app's
        // deadline scheduler, not on `clock` (a test's manual clock drives WebKit tabs only).
        standInCap.schedule(after: cap) { [weak self, weak view] in
            guard let self, let view, self.standIn === view else { return }
            self.removeStandIn()
        }
        page.whenPainted { [weak self, weak view] in
            guard let self, let view, self.standIn === view else { return }
            self.removeStandIn()
        }
        return true
    }

    func removeStandIn() {
        standInCap.cancel()
        standIn?.removeFromSuperview()
        standIn = nil
    }
}
