import AppKit
import Foundation
import WebKit

/// Small pool of hidden, pre-navigated browser webviews.
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
    static let shared = BrowserPrewarmedWebViewPool(capacity: 2)

    private enum LoadState {
        case loading
        case finished
        case failed
    }

    private struct EntryKey: Hashable {
        let url: String
        let profileID: UUID
    }

    private struct Entry {
        let webView: CmuxWebView
        let url: URL
        let profileID: UUID
        let hostWindow: NSWindow
        let expiresAfter: Duration?
        var loadState: LoadState
        var lastRequestedAt: ContinuousClock.Instant
    }

    private var entries: [EntryKey: Entry] = [:]
    private var expiryTasks: [EntryKey: Task<Void, Never>] = [:]
    private let capacity: Int
    private let timeToLive: Duration
    private let trustedInlineTimeToLive: Duration
    private let makeWebView: @MainActor (UUID) -> CmuxWebView
    private let startLoad: @MainActor (CmuxWebView, URLRequest) -> Void
    private let expirySleep: @Sendable (Duration) async throws -> Void

    init(
        capacity: Int = 1,
        timeToLive: Duration = .seconds(180),
        trustedInlineTimeToLive: Duration = .seconds(30),
        makeWebView: @escaping @MainActor (UUID) -> CmuxWebView = { profileID in
            BrowserPanel.makeWebView(profileID: profileID)
        },
        startLoad: @escaping @MainActor (CmuxWebView, URLRequest) -> Void = { webView, request in
            webView.load(request)
        },
        expirySleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.capacity = max(1, capacity)
        self.timeToLive = timeToLive
        self.trustedInlineTimeToLive = trustedInlineTimeToLive
        self.makeWebView = makeWebView
        self.startLoad = startLoad
        self.expirySleep = expirySleep
    }

    /// Whether a live entry exists for the URL + profile, regardless of load
    /// state. Used to make repeat hovers cheap no-ops.
    func hasEntry(url: URL, profileID: UUID) -> Bool {
        entries[entryKey(url: url, profileID: profileID)] != nil
    }

    /// Starts (or keeps) a hidden webview loading `url`. Evicts the oldest
    /// entry only when the bounded pool is full; restarts this entry's expiry
    /// clock either way.
    ///
    /// Web URLs only, and never a URL the panel's insecure-HTTP interstitial
    /// would intercept: the hidden load runs without the panel's navigation
    /// delegate, so no prompt could be shown here. Sharing the panel's
    /// allowlist policy keeps http://localhost dev origins prewarmable.
    func prewarm(url: URL, profileID: UUID) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              !browserShouldBlockInsecureHTTPURL(url) else {
            return
        }
        prewarmValidated(url: url, profileID: profileID, expiresAfter: timeToLive)
    }

    /// Prewarms an app-authored inline page. The caller must supply a data URL;
    /// arbitrary local or custom-scheme URLs never enter the pool through this path.
    func prewarmTrustedInlinePage(url: URL, profileID: UUID) {
        guard url.scheme?.lowercased() == "data" else { return }
        prewarmValidated(
            url: url,
            profileID: profileID,
            expiresAfter: trustedInlineTimeToLive
        )
    }

    private func prewarmValidated(url: URL, profileID: UUID, expiresAfter: Duration?) {
        let key = entryKey(url: url, profileID: profileID)
        if entries[key] != nil {
            entries[key]?.lastRequestedAt = ContinuousClock.now
            scheduleExpiry(for: key)
            return
        }
        evictOldestEntryIfNeeded()

        let webView = makeWebView(profileID)
        webView.navigationDelegate = self
        let hostWindow = Self.makeHiddenHostWindow(for: webView)
        entries[key] = Entry(
            webView: webView,
            url: url,
            profileID: profileID,
            hostWindow: hostWindow,
            expiresAfter: expiresAfter,
            loadState: .loading,
            lastRequestedAt: ContinuousClock.now
        )
        startLoad(webView, URLRequest(url: url))
        scheduleExpiry(for: key)
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.start url=\(url.absoluteString) profile=\(profileID.uuidString.prefix(5))")
#endif
    }

    /// Hands the prewarmed webview to a panel when it matches the requested
    /// navigation, or returns nil for a normal cold load. The entry is
    /// consumed either way: once a matching panel is being created, a
    /// still-loading or failed entry is useless and would otherwise linger.
    func claim(url: URL, profileID: UUID, websiteDataStore: WKWebsiteDataStore) -> CmuxWebView? {
        let key = entryKey(url: url, profileID: profileID)
        guard let entry = entries[key] else { return nil }
        guard entry.loadState == .finished,
              entry.webView.configuration.websiteDataStore === websiteDataStore else {
            discard(key: key, reason: entry.loadState == .finished ? "datastore-mismatch" : "not-finished")
            return nil
        }
        let webView = entry.webView
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        webView.browserPortalPrepareForHiddenHostAdoption()
        entry.hostWindow.close()
        entries.removeValue(forKey: key)
        expiryTasks.removeValue(forKey: key)?.cancel()
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.claim url=\(url.absoluteString)")
#endif
        return webView
    }

    func discard(reason: String) {
        let keys = Array(entries.keys)
        for key in keys {
            discard(key: key, reason: reason)
        }
    }

    private func discard(key: EntryKey, reason: String) {
        expiryTasks.removeValue(forKey: key)?.cancel()
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.webView.navigationDelegate = nil
        entry.webView.stopLoading()
        entry.webView.removeFromSuperview()
        entry.hostWindow.close()
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.discard reason=\(reason)")
#endif
    }

    private func scheduleExpiry(for key: EntryKey) {
        expiryTasks.removeValue(forKey: key)?.cancel()
        guard let ttl = entries[key]?.expiresAfter else { return }
        let sleep = expirySleep
        expiryTasks[key] = Task { [weak self] in
            do {
                try await sleep(ttl)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.discard(key: key, reason: "expired")
        }
    }

    private func entryKey(url: URL, profileID: UUID) -> EntryKey {
        EntryKey(url: url.absoluteString, profileID: profileID)
    }

    private func evictOldestEntryIfNeeded() {
        guard entries.count >= capacity else { return }
        let expiringEntries = entries.filter { $0.value.expiresAfter != nil }
        let candidates = expiringEntries.isEmpty ? entries : expiringEntries
        guard let oldest = candidates.min(by: {
            $0.value.lastRequestedAt < $1.value.lastRequestedAt
        })?.key else { return }
        discard(key: oldest, reason: "capacity")
    }

    /// Offscreen, non-activating host so WebKit treats the webview as
    /// window-backed and completes rendering work while hidden. Sized to the
    /// main window's content area so the page lays out close to the pane the
    /// adopting panel will render into.
    private static func makeHiddenHostWindow(for webView: WKWebView) -> NSWindow {
        var size = NSSize(width: 1080, height: 760)
        if let contentSize = NSApp.mainWindow?.contentView?.bounds.size,
           contentSize.width >= 320, contentSize.height >= 240 {
            size = contentSize
        }
        let frame = NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height)
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
        guard let key = entries.first(where: { $0.value.webView === webView })?.key,
              var entry = entries[key] else { return }
        entry.loadState = state
        entries[key] = entry
    }

    private func entryKey(for webView: WKWebView) -> EntryKey? {
        entries.first(where: { $0.value.webView === webView })?.key
    }
}

extension BrowserPrewarmedWebViewPool: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateLoadState(for: webView, to: .finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let key = entryKey(for: webView) else { return }
        discard(key: key, reason: "load-failed")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let key = entryKey(for: webView) else { return }
        discard(key: key, reason: "provisional-load-failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let key = entryKey(for: webView) else { return }
        discard(key: key, reason: "webcontent-terminated")
    }
}
