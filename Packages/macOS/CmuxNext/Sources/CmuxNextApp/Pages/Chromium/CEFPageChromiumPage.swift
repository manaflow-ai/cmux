import AppKit
import CmuxNextBrowser
import CmuxNextCompat
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

    func load(_ url: URL) { tab.load(url) }

    func reload() { tab.reload() }

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
