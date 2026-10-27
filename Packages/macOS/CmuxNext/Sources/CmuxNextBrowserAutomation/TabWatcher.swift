import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import WebKit

/// Watches a driven tab, no polling:
/// - its navigation events (`WebKitTab.observeNavigationEvents`) go to the
///   load waits, which key them by navigation;
/// - from its engine-neutral state (`WebKitTab.state`, one automation-class
///   ``ServiceObservation``, p06-scheduler-036: the person's input goes first):
/// - a web content process exit emits `tab.crashed` and fails every wait;
/// - a web view URL change (KVO) outside a load is a same-document
///   navigation (fragment, pushState): `tab.navigated {sameDocument: true}`
///   and every wait is met (the document-start reporter does not run then).
@MainActor
final class TabWatcher {
    private weak var tab: WebKitTab?
    private weak var session: TabSession?
    private let emit: (String, [String: DriverJSON]) -> Void
    private var lastURL: URL?
    private var lastExit: BrowserProcessExit?
    private var stopped = false
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var navigationObserver: UUID?
    private var exitObservation: ServiceObservation<BrowserProcessExit?>?

    init(tab: WebKitTab, session: TabSession, work: MainWorkScheduler, emit: @escaping (String, [String: DriverJSON]) -> Void) {
        self.tab = tab
        self.session = session
        self.emit = emit
        lastURL = tab.webView.url
        lastExit = tab.state.processExit
        exitObservation = ServiceObservation(.automation, owner: "browser-automation.tab-exit", on: work) { [weak tab] in
            tab?.state.processExit
        } apply: { [weak self] exit in
            self?.processExited(exit)
        }
        // Commits, finishes and failures, keyed by navigation (LoadWaits).
        navigationObserver = tab.observeNavigationEvents { [weak session] event in session?.waits.navigationEvent(event) }
        // A load that never started a navigation ended: same-document (LoadWaits).
        loadingObservation = watch(tab.webView, \.isLoading) { watcher, webView in
            if !webView.isLoading { watcher.session?.waits.loadingEnded() }
        }
        // Same-document navigations change only the web view's URL.
        urlObservation = watch(tab.webView, \.url) { watcher, webView in watcher.urlChanged(webView.url, loading: webView.isLoading) }
    }

    /// One KVO of the driven tab's web view, delivered to `changed` on the main thread. It is the load waits' model
    /// (an agent drives tabs nobody sees), so it applies shown or hidden, in order with the navigation events.
    private func watch<Value>(_ webView: WKWebView, _ property: KeyPath<WKWebView, Value>,
                              _ changed: @escaping @MainActor @Sendable (TabWatcher, WKWebView) -> Void) -> NSKeyValueObservation {
        // raw-observer-allow: WKWebView reports isLoading and its URL only through KVO (no notice); it is the driven tab's own web view, no window's or app's
        webView.observe(property, options: [.new]) { @Sendable [weak self] webView, _ in
            // main-hop-allow: WebKit changes these on the main thread, so the change applies inline in that turn, in order with the navigation events LoadWaits keys by (a posted task would let a commit pass the load end it follows); only an off-main change hops
            MainDelivery().run {
                guard let self else { return }
                changed(self, webView)
            }
        }
    }

    func stop() {
        stopped = true
        exitObservation?.cancel()
        exitObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil
        loadingObservation?.invalidate()
        loadingObservation = nil
        if let navigationObserver { tab?.removeNavigationObserver(navigationObserver) }
        navigationObserver = nil
    }

    private func urlChanged(_ url: URL?, loading: Bool) {
        guard !stopped, let tab, let session, url != lastURL else { return }
        let previous = lastURL
        lastURL = url
        let provisional = if case .provisional = tab.state.phase { true } else { false }
        guard let url, let previous else { return }
        // A change of only the fragment is always same-document (HTML
        // navigation); pushState and replaceState change the URL outside a load.
        guard Self.differOnlyInFragment(previous, url) || (!provisional && !loading) else { return }
        session.waits.sameDocument()
        emit("tab.navigated", ["targetId": .string(tab.id.rawValue), "url": .string(url.absoluteString),
                               "frameId": session.frames.mainFrameID.map(DriverJSON.string) ?? .null,
                               "sameDocument": .bool(true)])
    }

    static func differOnlyInFragment(_ a: URL, _ b: URL) -> Bool {
        func base(_ url: URL) -> String {
            let text = url.absoluteString
            return text.firstIndex(of: "#").map { String(text[..<$0]) } ?? text
        }
        return a != b && base(a) == base(b)
    }

    private func processExited(_ exit: BrowserProcessExit?) {
        guard !stopped, let tab, let session, let exit, exit != lastExit else { return }
        lastExit = exit
        session.waits.failAll(DriverError(.closed, "the page's web content process ended"))
        emit("tab.crashed", ["targetId": .string(tab.id.rawValue)])
    }
}
