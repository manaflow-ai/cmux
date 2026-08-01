import AppKit
import Foundation
import WebKit

/// Single-slot pool of a hidden, pre-navigated browser webview.
///
/// Callers use ``prewarm(url:profileID:)`` so a page is already loading by the
/// time the user opens it. The ``BrowserPanel`` initializer claims a matching
/// entry via ``claim(url:profileID:websiteDataStore:)`` and adopts the webview
/// instead of starting a cold WebKit process launch plus network load, so the
/// panel shows the finished page immediately.
///
/// The webview normally lives in an offscreen, non-activating borderless
/// window (the same hosting recipe as
/// `BrowserPanel.ensureBackgroundPreloadHostIfNeeded`). A terminal link
/// preview may temporarily attach that exact webview to an on-screen preview
/// host without consuming it. A matching ``BrowserPanel`` can then claim the
/// view, including while navigation is still in flight, so opening a previewed
/// link never starts a second WebKit process or network load.
///
/// The entry expires `timeToLive` after the last prewarm request and is
/// discarded on load failure or web-content process termination, so a hover
/// that never becomes a click costs one background page load and is reclaimed.
@MainActor
final class BrowserPrewarmedWebViewPool: NSObject {
    static let shared = BrowserPrewarmedWebViewPool()

    enum LoadState: Equatable {
        case loading
        case finished
        case failed
    }

    struct Claim {
        let webView: CmuxWebView
        let loadState: LoadState
    }

    struct PreviewAttachment: Equatable {
        let id: UUID
        let loadState: LoadState
    }

    private struct Entry {
        let webView: CmuxWebView
        let url: URL
        let profileID: UUID
        let hostWindow: NSWindow
        var loadState: LoadState
        var previewAttachmentID: UUID?
        var previewStateDidChange: (@MainActor (LoadState) -> Void)?
        var previewDidDismiss: (@MainActor () -> Void)?
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
            BrowserPanel.makeWebView(profileID: profileID)
        },
        startLoad: @escaping @MainActor (CmuxWebView, URLRequest) -> Void = { webView, request in
            webView.applyBrowserUserAgentPolicy(for: request.url)
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
        if hasEntry(url: url, profileID: profileID) {
            scheduleExpiry()
            return
        }
        discard(reason: "replaced")

        let webView = makeWebView(profileID)
        _ = webView.cmuxSetPageAudioMuted(true)
        webView.navigationDelegate = self
        let hostWindow = Self.makeHiddenHostWindow(for: webView)
        entry = Entry(
            webView: webView,
            url: url,
            profileID: profileID,
            hostWindow: hostWindow,
            loadState: .loading,
            previewAttachmentID: nil,
            previewStateDidChange: nil,
            previewDidDismiss: nil
        )
        startLoad(webView, URLRequest(url: url))
        scheduleExpiry()
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.start url=\(url.absoluteString) profile=\(profileID.uuidString.prefix(5))")
#endif
    }

    /// Temporarily renders a matching entry inside an interactive preview
    /// host. The entry remains claimable by a real browser panel.
    func attachPreview(
        url: URL,
        profileID: UUID,
        to hostView: NSView,
        stateDidChange: @escaping @MainActor (LoadState) -> Void,
        didDismiss: @escaping @MainActor () -> Void
    ) -> PreviewAttachment? {
        guard var entry,
              entry.url.absoluteString == url.absoluteString,
              entry.profileID == profileID,
              entry.loadState != .failed else {
            return nil
        }

        entry.previewDidDismiss?()
        let attachmentID = UUID()
        entry.previewAttachmentID = attachmentID
        entry.previewStateDidChange = stateDidChange
        entry.previewDidDismiss = didDismiss
        Self.host(entry.webView, in: hostView)
        self.entry = entry
        scheduleExpiry()
        stateDidChange(entry.loadState)
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.preview.attach url=\(url.absoluteString)")
#endif
        return PreviewAttachment(id: attachmentID, loadState: entry.loadState)
    }

    /// Returns a previewed view to its hidden host without discarding the
    /// loaded page. A later click may still claim it until the TTL expires.
    func detachPreview(_ attachment: PreviewAttachment) {
        guard var entry, entry.previewAttachmentID == attachment.id else { return }
        entry.previewAttachmentID = nil
        entry.previewStateDidChange = nil
        entry.previewDidDismiss = nil
        if let hiddenHost = entry.hostWindow.contentView {
            Self.host(entry.webView, in: hiddenHost)
            entry.hostWindow.orderFrontRegardless()
        }
        self.entry = entry
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.preview.detach url=\(entry.url.absoluteString)")
#endif
    }

    /// Hands the prewarmed webview to a panel when it matches the requested
    /// navigation, or returns nil for a normal cold load. Both finished and
    /// in-flight navigations are adopted so a click during preview loading does
    /// not start over.
    func claim(url: URL, profileID: UUID, websiteDataStore: WKWebsiteDataStore) -> Claim? {
        guard let entry,
              entry.url.absoluteString == url.absoluteString,
              entry.profileID == profileID else {
            return nil
        }
        guard entry.loadState != .failed,
              entry.webView.configuration.websiteDataStore === websiteDataStore else {
            discard(reason: entry.loadState == .failed ? "failed" : "datastore-mismatch")
            return nil
        }
        let webView = entry.webView
        self.entry = nil
        expiryTask?.cancel()
        expiryTask = nil
        entry.previewDidDismiss?()
        webView.navigationDelegate = nil
        _ = webView.cmuxSetPageAudioMuted(false)
        webView.removeFromSuperview()
        webView.browserPortalPrepareForHiddenHostAdoption()
        entry.hostWindow.close()
#if DEBUG
        cmuxDebugLog("browser.prewarmPool.claim url=\(url.absoluteString) state=\(entry.loadState)")
#endif
        return Claim(webView: webView, loadState: entry.loadState)
    }

    func discard(reason: String) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let entry else { return }
        self.entry = nil
        entry.previewDidDismiss?()
        entry.webView.navigationDelegate = nil
        entry.webView.stopLoading()
        entry.webView.removeFromSuperview()
        entry.hostWindow.close()
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
        host(webView, in: contentView)
        window.contentView = contentView
        window.orderFrontRegardless()
        return window
    }

    private static func host(_ webView: WKWebView, in hostView: NSView) {
        webView.removeFromSuperview()
        webView.frame = hostView.bounds
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)
    }

    private func updateLoadState(for webView: WKWebView, to state: LoadState) {
        guard var entry, entry.webView === webView else { return }
        entry.loadState = state
        self.entry = entry
        entry.previewStateDidChange?(state)
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
