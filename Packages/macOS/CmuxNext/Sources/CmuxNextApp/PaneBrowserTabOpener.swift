import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs

/// Opens a browser tab in one pane: daemon-owned when supported, on the
/// engine `BrowserTabService.resolve` picks (an explicit engine, else
/// `browser.defaultEngine`, Chromium, with the WebKit fallback), else
/// session-local. The new tab is selected and focused when it lands; a
/// blank tab focuses its address bar so the user can type a URL.
/// `PaneController.newBrowserTab` is its entry point; a value is made per
/// request and holds its pane until the daemon's answer.
@MainActor
struct PaneBrowserTabOpener {
    let controller: PaneController

    /// Whether a session-local (WebKit) tab may stand in when the daemon
    /// cannot make browser tabs.
    /// Never for a Chromium request or a Chromium internal page: those are
    /// refused rather than shown by the wrong engine.
    nonisolated static func allowsSessionLocalTab(url: URL?, requested: String?) -> Bool {
        if BrowserEngineResolver.explicitEngine(requested) == .cef { return false }
        return !(url.map(ChromiumInternalURL.needsChromium) ?? false)
    }

    /// `inherited` is a reopened or duplicated tab's engine or a popup
    /// opener's (falls back instead of refusing). `adopting` is a popup page
    /// the engine already created (`BrowserPageRequests`). `background` (a
    /// page's Cmd-click) creates the tab without selecting it. `profile` is
    /// an explicit browser profile (else the workspace's, the room's or
    /// `default`); `notice` shows on the new page; `then` runs with the new
    /// surface once the daemon made the tab. `opener` is the tab of the page
    /// that asked for it: the new tab goes next to it in Chrome's order
    /// (`BrowserTabOpeners`); without it the tab goes to the end.
    /// False when the tab is refused (no tab, no daemon request). A local file goes where
    /// `LocalFileHandoff` shows it (a tab's first load is not guarded): Markdown opens the markdown
    /// page unless the caller waits for the tab, and media Chromium cannot play opens in WebKit.
    func open(url: URL?, engine requested: String?, inherited: String?, adopting child: (any BrowserTab)?,
              background: Bool, profile: String?, notice: String?, opener: SurfaceID?,
              then: (@MainActor (SurfaceID) -> Void)?) -> Bool {
        let services = controller.services
        if child == nil, then == nil, let url, services.viewers.openMarkdownHandoff(url, in: controller, focus: !background) {
            return true
        }
        let requested = requested ?? (child == nil && inherited == nil ? url.flatMap(FilePageOpener.tabEngine(for:)) : nil)
        let browserTabs = services.cache.browserTabs!
        if browserTabs.isAvailable() {
            var choice: BrowserEngineChoice
            switch browserTabs.resolve(requested: requested, inherited: inherited) {
            case .refuse(let reason):
                services.registry.refuse(BrowserTabService.message(reason))
                return false
            case .open(let resolved): choice = resolved
            }
            if child != nil { choice = BrowserPageRequests.choice(adopting: child, inherited: inherited, browserTabs: browserTabs) }
            let pageRequests = services.cache.pageRequests
            let newTabAddress = services.newTabAddress(for: choice)
            let controller = controller, handle = controller.pane.handle, model = controller.pane
            let intent = background ? nil : controller.workspace?.beginFocusIntent()
            services.registry.track(Task {
                do {
                    // A new tab the user asked for opens the New Tab page; an
                    // adopted page (popup, extension tab) keeps its own.
                    let address = url?.absoluteString ?? (child == nil ? newTabAddress : BrowserNewTabPage.blankURL)
                    let surface = try await pageRequests.openers.open(opener, foreground: !background, in: model,
                                                                      browserTabs: browserTabs) { after in
                        try await browserTabs.open(choice, in: handle, url: address, profile: profile, notice: notice, after: after)
                    }
                    if let child { pageRequests.adopt(child, surface: surface) }
                    then?(surface)
                    guard !background else { return nil }
                    controller.selectWhenReported(surface: surface)
                    controller.workspace?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, generation: intent)
                    return nil
                } catch {
                    child?.close()
                    controller.daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                    return "new-frontend-browser-tab: \(error)"
                }
            })
            return true
        }
        guard Self.allowsSessionLocalTab(url: url, requested: requested) else {
            child?.close()
            services.registry.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.frontendBrowserTabs))
            return false
        }
        child?.close()  // Session-local tabs are WebKit pages made on demand.
        let local = LocalBrowserTab.make(url: url)
        controller.state?.localBrowserTabs[controller.paneKey, default: []].append(local)
        controller.apply(controller.snapshot())
        if background { return true }
        controller.select(StripTabID(local.id))
        if url == nil { controller.workspace?.focus.send(.focusTarget(.addressBar, source: .intent)) }
        return true
    }
}
