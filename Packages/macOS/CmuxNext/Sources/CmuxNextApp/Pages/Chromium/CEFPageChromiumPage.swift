import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import Foundation
import os

/// One cmux page in a CEF tab (``PageChromiumPage``). The page host drives it through the DevTools
/// protocol: the tab's raw relay (`CEFAgentRelay`) carries the protocol events (the bridge's
/// binding calls, `Page.frameNavigated`, `Page.loadEventFired`); a page tab is never an agent's tab,
/// so nothing else listens on its relay. The tab's own state reports a crash.
@MainActor
final class CEFPageChromiumPage: PageChromiumPage, BrowserTabDelegate {
    /// The CEF tab the page shows in; the focus applier gives it the keyboard like a browser tab.
    let tab: CEFTab
    private let pageID: String
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.chromium")
    private var crashWatch: Task<Void, Never>?
    private var closed = false

    init(tab: CEFTab, pageID: String) {
        self.tab = tab
        self.pageID = pageID
    }

    var contentView: NSView { tab.contentView }

    /// The tab's holes for native UI (`CEFTab.occlusionRects`, `contentView` coordinates).
    var occlusionRects: [CGRect] {
        get { tab.occlusionRects }
        set { if tab.occlusionRects != newValue { tab.occlusionRects = newValue } }
    }

    /// The tab's page window clip (`CEFTab.pageWindowClip`, window coordinates).
    var windowClip: CGPath? { tab.pageWindowClip }

    var onEvent: ((PageChromiumEvent) -> Void)? {
        didSet { listen() }
    }

    var resources: (@MainActor (URL, String?) async -> PageChromiumResponse)? {
        didSet {
            guard let resources else {
                tab.pageResources = nil
                return
            }
            tab.pageResources = { url, range in
                let answer = await resources(url, range)
                return CEFPageResponse(status: answer.status, mimeType: answer.mimeType, body: answer.body, rangeHeaders: answer.rangeHeaders,
                                       csp: answer.csp)
            }
        }
    }

    private func listen() {
        guard onEvent != nil, !closed else {
            tab.clearPageEventHooks()
            crashWatch?.cancel()
            crashWatch = nil
            return
        }
        tab.agentRelay.set(onMessage: { [weak self] json in self?.onEvent?(.devTools(json)) },
                           onEnd: { [weak self] in self?.renderEnded() })
        tab.pageFilesDragged = { [weak self] urls in self?.onEvent?(.filesDragged(urls)) }
        tab.pageDragEnded = { [weak self] dropped in self?.onEvent?(.dragEnded(dropped: dropped)) }
        tab.pageUserInput = { [weak self] uptime in self?.onEvent?(.userInput(uptime)) }
        tab.pagePasted = { [weak self] in self?.onEvent?(.pasted) }
        guard crashWatch == nil else { return }
        let tab = tab
        crashWatch = Task { [weak self] in
            for await exit in ObservationStream({ tab.state.processExit }) where exit != nil {
                self?.onEvent?(.crashed)
            }
        }
    }

    private func renderEnded() {
        guard !closed else { return }
        onEvent?(.ended)
    }

    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        try await tab.devTools(method: method, params: params)
    }

    func devTools(_ method: String, params: [String: any Sendable], timeout: Duration) async throws -> String {
        try await tab.devTools(method: method, params: params, timeout: timeout)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    func debugPress(at point: NSPoint) -> Bool {
        let host = contentView
        guard point.x.isFinite, point.y.isFinite, let window = host.window,
              !host.isHiddenOrHasHiddenAncestor else { return false }
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        guard host.bounds.contains(local) else { return false }
        let screen = window.convertPoint(toScreen: host.convert(local, to: nil))
        guard let page = WindowOverlayHost.frontPageWindow(at: screen, in: window) else { return false }
        let location = page.convertPoint(fromScreen: screen)
        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: now,
                                            windowNumber: page.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: now + 0.001,
                                          windowNumber: page.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { return false }
        // Giving this app's page the key does not activate the app. The queued events then take
        // the normal native path, including CEFLinkClickTracker's local input monitor.
        page.makeKey()
        SyntheticInput.register([down, up])
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return true
    }
    #endif

    func load(_ url: URL) { tab.load(url) }

    func reload() { tab.reload() }

    func setZoom(_ zoom: Double) { tab.setZoom(zoom) }

    func setFocused(_ focused: Bool) { tab.setFocused(focused) }

    func setVisible(_ visible: Bool) { tab.setContentVisible(visible) }

    func setSeeThrough(_ seeThrough: Bool) { tab.pageSeeThrough = seeThrough }

    func setAnswersFileChooser(_ on: Bool) { if on { tab.pageFilesChosen = { [weak self] urls in self?.onEvent?(.filesChosen(urls)) } } else { tab.pageFilesChosen = nil } }

    func close() {
        guard !closed else { return }
        closed = true
        crashWatch?.cancel()
        crashWatch = nil
        tab.clearPageHooks()
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
    /// The tab whose page shows in a Chromium child window: a Chromium browser tab, or a cmux page in Chromium
    /// (an agent chat, New Tab, the docked Home's Channels page: ``PageWebView/shown(in:)``).
    var childWindowTab: (any BrowserTab)? {
        switch self {
        case .browser(let entry): entry.tab.presentation == .childWindow ? entry.tab : nil
        case .page(let view): (PageWebView.shown(in: view.content)?.chromiumPage as? CEFPageChromiumPage)?.tab
        case .agent(let view): (view.chromiumPage as? CEFPageChromiumPage)?.tab
        default: nil
        }
    }
}
