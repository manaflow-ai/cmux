import AppKit
import CmuxNextWakeups
import Foundation
import WebKit

/// What a page view needs to start its document: the Chromium host the engine decision may use,
/// and when the open was asked for (the start of its `webui.open` slice).
struct PageFirstShowStart {
    let chromium: (any PageChromiumHosting)?
    let requested: TimeInterval
}

// No renderer before the first show (p07-memory-048, feature `pageRendererAtFirstShow`). A page
// opened hidden (a background tab, a tab of a hidden workspace) keeps its view, router and bridge,
// and starts its document, and with it its WebKit WebContent process or Chromium renderer, only
// when it first shows. Until then the view draws nothing over the window's backdrop, as any page
// does before its first paint. This is Chrome's delayed load of a tab that has not shown:
// `NavigationControllerImpl::SetNeedsReload` marks it, and `WebContentsImpl::WasShown` ->
// `NavigationControllerImpl::SetActive` -> `LoadIfNecessary` loads it
// (content/browser/renderer_host/navigation_controller_impl.cc). WebKit launches no WebContent
// process for a WKWebView that never loaded (`WebPageProxy::launchProcess` runs at the first load).
extension PageWebView {
    /// True while the page waits for its first show to start its document.
    public var awaitsFirstShow: Bool { firstShowStart != nil }

    /// The page shows (``setEngineVisible(_:)``, which the view's window and hide callbacks call
    /// with its visibility): a page that waited for its first show starts its document.
    func startAtFirstShow() {
        guard let start = firstShowStart else { return }
        firstShowStart = nil
        startDocument(PageFirstShowStart(chromium: start.chromium, requested: ProcessInfo.processInfo.systemUptime))
    }

    /// Starts the document at ``route`` in the engine ``engineDecision`` picked.
    func startDocument(_ start: PageFirstShowStart) {
        traceOpenRequested(.newView, constructedSince: start.requested)
        if engineDecision.engine == .cef, let hosting = start.chromium {
            startChromium(hosting: hosting)
        } else {
            #if DEBUG || CMUX_BENCH_HOOKS
            traceMark(.navigationStart)
            #endif
            webView.load(URLRequest(url: descriptor.url(route: route)))
        }
    }
}
