import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import os

/// One cmux page in a CEF tab (``PageChromiumPage``). The page host runs its scripts through the
/// tab's own evaluation (``evaluate(_:)``), takes pictures with its surface copy and clicks and moves with its
/// native input; the rest goes through the DevTools protocol: the tab's raw relay (`CEFAgentRelay`) carries the protocol events (the bridge's
/// binding calls, `Page.frameNavigated`, `Page.loadEventFired`); a page tab is never an agent's tab,
/// so nothing else listens on its relay. The tab's own state reports a crash and, with a hang scheduler
/// (feature `pageHangNotice`), a hang.
@MainActor
final class CEFPageChromiumPage: PageChromiumPage, BrowserTabDelegate {
    /// The CEF tab the page shows in; the focus applier gives it the keyboard like a browser tab.
    let tab: CEFTab
    private let pageID: String
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.chromium")
    private var crashWatch: Task<Void, Never>?
    /// Follows the tab's hang while the host listens (``PageChromiumEvent/unresponsive``).
    private var hangWatch: ServiceObservation<Bool>?
    /// The hang the host was last told of.
    private var hangReported = false
    /// The scheduler the hang watch flushes on; nil: the tab's hang never reaches the page host and
    /// Chromium waits on it until the renderer answers again, as before the feature.
    private let hangWork: MainWorkScheduler?
    private var closed = false

    /// - Parameters:
    ///   - tab: The CEF tab the page shows in.
    ///   - pageID: The page's id (logs).
    ///   - hangWork: Forward the tab's hang and its end, flushed on this scheduler (feature `pageHangNotice`); nil: never.
    init(tab: CEFTab, pageID: String, hangWork: MainWorkScheduler? = nil) {
        self.tab = tab
        self.pageID = pageID
        self.hangWork = hangWork
    }

    var contentView: NSView { tab.contentView }

    /// The tab's holes for native UI (`CEFTab.occlusionRects`, `contentView` coordinates).
    var occlusionRects: [CGRect] {
        get { tab.occlusionRects }
        set { if tab.occlusionRects != newValue { tab.occlusionRects = newValue } }
    }

    /// The tab's own page window (`CEFTab.isPageWindow(_:)`).
    func isPageWindow(_ window: NSWindow) -> Bool { tab.isPageWindow(window) }

    /// The one renderer that runs the page's frames, the page's renderer for its crash budget
    /// (`PageCrashGroups`); nil before the browser exists or while frames run in more than one.
    var soleRendererClientID: Int32? {
        guard case .chromiumRendererClients(let clients) = tab.contentProcesses, clients.count == 1 else { return nil }
        return clients[0]
    }

    var onEvent: ((PageChromiumEvent) -> Void)? {
        didSet { listen() }
    }

    var resources: (@MainActor (URL) async -> PageChromiumResponse)? {
        didSet {
            guard let resources else {
                tab.pageResources = nil
                return
            }
            tab.pageResources = { url in
                let answer = await resources(url)
                return CEFPageResponse(status: answer.status, mimeType: answer.mimeType, body: answer.body)
            }
        }
    }

    private func listen() {
        guard onEvent != nil, !closed else {
            tab.pageFilesDragged = nil
            tab.pageUserInput = nil
            tab.agentRelay.set(onMessage: nil, onEnd: nil)
            crashWatch?.cancel()
            crashWatch = nil
            hangWatch?.cancel()
            hangWatch = nil
            hangReported = false
            return
        }
        tab.agentRelay.set(onMessage: { [weak self] json in self?.onEvent?(.devTools(json)) },
                           onEnd: { [weak self] in self?.renderEnded() })
        tab.pageFilesDragged = { [weak self] urls in self?.onEvent?(.filesDragged(urls)) }
        tab.pageUserInput = { [weak self] uptime in self?.onEvent?(.userInput(uptime)) }
        let tab = tab
        if crashWatch == nil {
            crashWatch = Task { [weak self] in
                for await exit in ObservationStream({ tab.state.processExit }) where exit != nil {
                    self?.onEvent?(.crashed)
                }
            }
        }
        if let hangWork, hangWatch == nil {
            // Chrome's `WebContentsDelegate::RendererUnresponsive` / `RendererResponsive` pair
            // (chrome/browser/ui/browser.cc): the tab's state machine already folds the shim's
            // RENDER_UNRESPONSIVE / RESPONSIVE events and a renderer exit into `isUnresponsive`.
            hangWatch = ServiceObservation(.visible, owner: "CEFPageChromiumPage.hang", on: hangWork) {
                tab.state.isUnresponsive
            } apply: { [weak self] hung in
                self?.reportHang(hung)
            }
        }
    }

    private func reportHang(_ hung: Bool) {
        guard hung != hangReported else { return }
        hangReported = hung
        onEvent?(hung ? .unresponsive : .responsive)
    }

    private func renderEnded() {
        guard !closed else { return }
        onEvent?(.ended)
    }

    /// The tab's DevTools call; a call the host's end failed (the page's setup, before its session
    /// hears ``PageChromiumEvent/ended``) throws ``PageChromiumStartError/browserEnded``.
    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        do {
            return try await tab.devTools(method: method, params: params)
        } catch where tab.browserEndedWithHost {
            throw PageChromiumStartError.browserEnded
        }
    }

    /// The tab's own evaluation, in the page's world with no gesture: the fork's `tabEvaluate` on
    /// renderer paths (fork API 29), so the page's scripts make no DevTools call there, else a
    /// `Runtime.evaluate`. The tab answers undefined as null, so both come back as `NSNull`.
    func evaluate(_ script: String) async throws -> Any? {
        let value: BrowserJSValue
        do {
            value = try await tab.evaluate(script, world: .page, gesture: .cmux)
        } catch BrowserTabError.javaScript(let text) {
            throw PageScriptError.exception(text)
        }
        return Self.foundation(value)
    }

    /// `value` with the types `JSONSerialization` gives (`NSNumber` for a number, so `as? Int`
    /// reads an integer as it does on the DevTools path).
    private static func foundation(_ value: BrowserJSValue) -> Any {
        switch value {
        case .number(let number): return NSNumber(value: number)
        case .array(let values): return values.map(foundation)
        case .object(let values): return values.mapValues(foundation)
        case .null, .bool, .string: return value.foundationValue
        }
    }

    /// The tab's surface copy (`CEFTab.copySurface`, fork API 38): the fork's `cmux_browser_capture`.
    var copiesSurface: Bool { !closed && tab.copiesSurface }

    /// The tab's surface copy, sent in this turn, answered still in base64 (the page host decodes it off
    /// the main thread). None on a fork without it: a DevTools `Page.captureScreenshot` would attach an
    /// agent and end renderer sharing, so a discarded page with no picture shows its pane's background
    /// until the page draws again.
    func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (PageSurfaceCopy?) -> Void) {
        guard !closed else { return done(nil) }
        tab.copySurface(maxPixelSize: maxPixelSize) { copy in
            done(copy.map { PageSurfaceCopy(base64: $0.base64, pixelSize: $0.pixelSize) })
        }
    }

    /// The tab's native click (`CEFTab.sendClick`, fork API 29); false on an older fork or a closed page.
    func sendClick(at point: CGPoint) -> Bool {
        !closed && tab.sendClick(x: point.x, y: point.y)
    }

    /// The tab's native mouse move (`CEFTab.sendMouseMove`); false on a fork without it or a closed page.
    func sendMouseMove(at point: CGPoint) -> Bool {
        !closed && tab.sendMouseMove(x: point.x, y: point.y)
    }

    /// `document.execCommand('copy')` as the person's own command (`CEFTab.perform`, gesture `.agent`), sent
    /// in this turn with nothing waiting on it.
    func copySelection() {
        guard !closed else { return }
        _ = tab.perform("document.execCommand('copy')", gesture: .agent)
    }

    /// After an in-place discard, the discarded entry's own URL comes back by Chromium's restore on
    /// show and sends nothing (`CEFTab.loadRestoringDiscard(_:)`).
    func load(_ url: URL) { tab.loadRestoringDiscard(url) }

    func reload() { tab.reload() }

    /// The tab's in-place discard (`CEFTab.discard()`); false on a fork without it and in host mode.
    func discard() -> Bool {
        !closed && tab.discard()
    }

    func setZoom(_ zoom: Double) { tab.setZoom(zoom) }

    func setFocused(_ focused: Bool) { tab.setFocused(focused) }

    func setVisible(_ visible: Bool) { tab.setContentVisible(visible) }

    /// The tab moves into `window`'s page window (`CEFTab.moveToPagesPane(_:)`). A fork before
    /// `cmux_tab_move_to_window` (API 3, older than any fork cmux ships) cannot move it: it stays where it is.
    func moveWindow(to window: PageChromiumWindow) {
        guard !closed, !tab.moveToPagesPane(ChromiumPageHost.pane(of: window)) else { return }
        logger.error("page \(self.pageID, privacy: .public) stays in its Chromium window: the tab cannot move")
    }

    /// The tab's page lifecycle (`CEFTab.setFrozen`: the fork's `SetPageFrozen`, DevTools before
    /// fork API 29). A closed page changes nothing.
    @discardableResult
    func setFrozen(_ frozen: Bool) -> Bool {
        guard !closed else { return false }
        return tab.setFrozen(frozen)
    }

    func setSeeThrough(_ seeThrough: Bool) { tab.pageSeeThrough = seeThrough }

    /// The tab's answer to its hang (`CEFTab.answerUnresponsivePage`: the shim's
    /// `cmux_shim_unresponsive_reply`, which posts and returns). A closed page answers nothing.
    func answerUnresponsive(terminate: Bool) {
        guard !closed else { return }
        tab.answerUnresponsivePage(terminate: terminate)
    }

    func close() {
        guard !closed else { return }
        closed = true
        crashWatch?.cancel()
        crashWatch = nil
        hangWatch?.cancel()
        hangWatch = nil
        tab.agentRelay.set(onMessage: nil, onEnd: nil)
        tab.pageResources = nil
        tab.pageFilesDragged = nil
        tab.pageUserInput = nil
        tab.delegate = nil
        tab.close()
    }

    // MARK: BrowserTabDelegate

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case .openURL(let url, _):
            onEvent?(.openRequested(url))
        case .adoptTab(let opened, _), .openPopup(let opened, _):
            // `window.open` from a cmux page: no page may make windows; its URL opens like a link.
            if let url = opened.state.url { onEvent?(.openRequested(url)) }
            opened.close()
        case .contextMenu(let request):
            // The page host builds the menu the WebKit page shows; Chromium's own rows do not show.
            guard let onEvent else { return request.complete(nil) }
            onEvent(.contextMenu(PageChromiumContextMenu(location: request.location, selection: request.target.selection,
                                                         isEditable: request.target.isEditable) { request.complete(nil) }))
        case .notice(let text):
            logger.info("page \(self.pageID, privacy: .public) notice: \(text, privacy: .public)")
        default:
            break
        }
    }
}

extension TabContent {
    /// The Chromium tab that shows this content's page, in either backend: a Chromium browser tab,
    /// or a cmux page (an agent chat or New Tab page too) in Chromium.
    var chromiumTab: (any BrowserTab)? {
        switch self {
        case .browser(let entry): entry.tab as? CEFTab
        case .page(let view): ((view.content as? PageWebView)?.chromiumPage as? CEFPageChromiumPage)?.tab
        case .agent(let view): (view.chromiumPage as? CEFPageChromiumPage)?.tab
        default: nil
        }
    }

    /// ``chromiumTab`` when its page shows in a Chromium child window: in process only. In host
    /// mode the page is a view in the pane (``BrowserPresentation/inView``), so this is nil.
    var childWindowTab: (any BrowserTab)? {
        guard let tab = chromiumTab, tab.presentation == .childWindow else { return nil }
        return tab
    }
}
