import AppKit
import Foundation
import WebKit

/// Single-slot pool of a hidden, pre-navigated browser webview.
///
/// Upgrade entrypoints call ``prewarm(url:profileID:)`` on hover so the
/// pricing page is already loaded by the time the user clicks. The
/// ``BrowserPanel`` initializer claims a matching entry via
/// ``claim(url:profileID:websiteDataStore:)`` and adopts the webview instead
/// of starting a cold WebKit process launch plus network load, so the panel
/// shows the finished page immediately.
///
/// The pool never renders on screen: the webview lives in an offscreen,
/// non-activating borderless window (the same hosting recipe as
/// `BrowserPanel.ensureBackgroundPreloadHostIfNeeded`). The entry expires
/// `timeToLive` after the last prewarm request and is discarded on load
/// failure or web-content process termination, so a hover that never becomes
/// a click costs one background page load and is reclaimed.
@MainActor
final class BrowserPrewarmedWebViewPool: NSObject {
    static let shared = BrowserPrewarmedWebViewPool()

    private enum LoadState {
        case loading
        case finished
        case failed
    }

    private struct Entry {
        let webView: CmuxWebView
        let url: URL
        let profileID: UUID
        let hostWindow: NSWindow
        var loadState: LoadState
    }

    private var entry: Entry?
    private var expiryTask: Task<Void, Never>?
    private let timeToLive: Duration
    private let makeWebView: @MainActor (UUID) -> CmuxWebView
    private let startLoad: @MainActor (CmuxWebView, URLRequest) -> Void
    private let expirySleep: @Sendable (Duration) async throws -> Void

    init(
        timeToLive: Duration = .seconds(180),
        makeWebView: @escaping @MainActor (UUID) -> CmuxWebView = { profileID in
            BrowserPanel.makePrewarmedWebView(profileID: profileID)
        },
        startLoad: @escaping @MainActor (CmuxWebView, URLRequest) -> Void = { webView, request in
            webView.load(request)
        },
        expirySleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeToLive = timeToLive
        self.makeWebView = makeWebView
        self.startLoad = startLoad
        self.expirySleep = expirySleep
    }

    /// Whether a live entry exists for the URL + profile, regardless of load
    /// state. Used to make repeat hovers cheap no-ops.
    func hasEntry(url: URL, profileID: UUID) -> Bool {
        guard let entry else { return false }
        return entry.url.absoluteString == url.absoluteString && entry.profileID == profileID
    }

    /// Starts (or keeps) a hidden webview loading `url`. Replaces any entry
    /// for a different URL or profile; restarts the expiry clock either way.
    ///
    /// HTTPS only: the hidden load runs without the panel's navigation
    /// delegate, so the insecure-HTTP interstitial can't be shown here.
    func prewarm(url: URL, profileID: UUID) {
        guard url.scheme?.lowercased() == "https" else { return }
        if hasEntry(url: url, profileID: profileID) {
            scheduleExpiry()
            return
        }
        discard(reason: "replaced")

        let webView = makeWebView(profileID)
        webView.navigationDelegate = self
        let hostWindow = Self.makeHiddenHostWindow(for: webView)
        entry = Entry(
            webView: webView,
            url: url,
            profileID: profileID,
            hostWindow: hostWindow,
            loadState: .loading
        )
        startLoad(webView, URLRequest(url: url))
        scheduleExpiry()
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.start url=\(url.absoluteString) profile=\(profileID.uuidString.prefix(5))")
#endif
    }

    /// Hands the prewarmed webview to a panel when it matches the requested
    /// navigation, or returns nil for a normal cold load. The entry is
    /// consumed either way: once a matching panel is being created, a
    /// still-loading or failed entry is useless and would otherwise linger.
    func claim(url: URL, profileID: UUID, websiteDataStore: WKWebsiteDataStore) -> CmuxWebView? {
        guard let entry,
              entry.url.absoluteString == url.absoluteString,
              entry.profileID == profileID else {
            return nil
        }
        guard entry.loadState == .finished,
              entry.webView.configuration.websiteDataStore === websiteDataStore else {
            discard(reason: entry.loadState == .finished ? "datastore-mismatch" : "not-finished")
            return nil
        }
        let webView = entry.webView
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        entry.hostWindow.close()
        self.entry = nil
        expiryTask?.cancel()
        expiryTask = nil
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.claim url=\(url.absoluteString)")
#endif
        return webView
    }

    func discard(reason: String) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let entry else { return }
        entry.webView.navigationDelegate = nil
        entry.webView.stopLoading()
        entry.webView.removeFromSuperview()
        entry.hostWindow.close()
        self.entry = nil
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.discard reason=\(reason)")
#endif
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let ttl = timeToLive
        let sleep = expirySleep
        expiryTask = Task { [weak self] in
            do {
                try await sleep(ttl)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.discard(reason: "expired")
        }
    }

    /// Offscreen, non-activating host so WebKit treats the webview as
    /// window-backed and completes rendering work while hidden.
    private static func makeHiddenHostWindow(for webView: WKWebView) -> NSWindow {
        let frame = NSRect(x: -10_000, y: -10_000, width: 1080, height: 760)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserPrewarmPool")
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        window.orderFrontRegardless()
        return window
    }

    private func updateLoadState(for webView: WKWebView, to state: LoadState) {
        guard var entry, entry.webView === webView else { return }
        entry.loadState = state
        self.entry = entry
    }
}

extension BrowserPrewarmedWebViewPool: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateLoadState(for: webView, to: .finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let entry, entry.webView === webView else { return }
        discard(reason: "load-failed")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let entry, entry.webView === webView else { return }
        discard(reason: "provisional-load-failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let entry, entry.webView === webView else { return }
        discard(reason: "webcontent-terminated")
    }
}
