import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextPages
import Foundation
import os

/// One cmux page in a CEF tab (``PageChromiumPage``). The page host runs its scripts through the
/// tab's own evaluation (``evaluate(_:)``) and the rest through the DevTools protocol: the tab's raw relay (`CEFAgentRelay`) carries the protocol events (the bridge's
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

    /// The tab's own page window (`CEFTab.isPageWindow(_:)`).
    func isPageWindow(_ window: NSWindow) -> Bool { tab.isPageWindow(window) }

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
            return
        }
        tab.agentRelay.set(onMessage: { [weak self] json in self?.onEvent?(.devTools(json)) },
                           onEnd: { [weak self] in self?.renderEnded() })
        tab.pageFilesDragged = { [weak self] urls in self?.onEvent?(.filesDragged(urls)) }
        tab.pageUserInput = { [weak self] uptime in self?.onEvent?(.userInput(uptime)) }
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

    /// No picture until p13-webui-078 binds the fork's `cmux_tab_copy_surface` (p13-webui-077) on the tab,
    /// and none on a fork without it: the DevTools `Page.captureScreenshot` the window image uses would
    /// attach an agent and end renderer sharing. A discarded page with no picture shows its pane's
    /// background until the page draws again.
    func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (PageEncodedSnapshot?) -> Void) { done(nil) }

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

    func setSeeThrough(_ seeThrough: Bool) { tab.pageSeeThrough = seeThrough }

    func close() {
        guard !closed else { return }
        closed = true
        crashWatch?.cancel()
        crashWatch = nil
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
