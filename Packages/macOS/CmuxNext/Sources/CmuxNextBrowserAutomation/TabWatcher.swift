import CmuxNextBrowser
import Foundation
import Observation

/// Watches a driven tab's engine-neutral state (`WebKitTab.state`, written
/// by WebKitTab's navigation delegate) with Observation, no polling:
/// - a failed navigation fails the waits no commit met, with its error;
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

    init(tab: WebKitTab, session: TabSession, emit: @escaping (String, [String: DriverJSON]) -> Void) {
        self.tab = tab
        self.session = session
        self.emit = emit
        lastURL = tab.webView.url
        lastExit = tab.state.processExit
        observe()
        // Same-document navigations change only the web view's URL.
        urlObservation = tab.webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.urlChanged(webView.url, loading: webView.isLoading) }
        }
    }

    func stop() {
        stopped = true
        urlObservation?.invalidate()
        urlObservation = nil
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

    private func observe() {
        guard !stopped, let tab else { return }
        let state = withObservationTracking {
            tab.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(state, tab: tab)
    }

    private func apply(_ state: BrowserTabState, tab: WebKitTab) {
        guard let session else { return }
        let target = DriverJSON.string(tab.id.rawValue)
        if case .failed(let error) = state.phase {
            session.waits.navigationFailed(DriverError(.invalid, "navigation failed: \(error.message)"))
        }
        if let exit = state.processExit, exit != lastExit {
            lastExit = exit
            session.waits.failAll(DriverError(.closed, "the page's web content process ended"))
            emit("tab.crashed", ["targetId": target])
        }
    }
}
