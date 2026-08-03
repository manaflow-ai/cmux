import AppKit
import Foundation
import WebKit

/// Keeps a small pool of fully rendered, inert Code first frames. A panel
/// adopts one of these web views, attaches it to the visible portal, and only
/// then activates the live runtime. This makes the first frame a view swap
/// instead of a new WebKit navigation while keeping hidden web views static.
@MainActor
final class CodeWebViewWarmer: NSObject {
    static let shared = CodeWebViewWarmer()

    private enum LoadState {
        case loading
        case finished
    }

    private struct Entry {
        let webView: CmuxWebView
        let profileID: UUID
        let websiteDataStore: WKWebsiteDataStore
        let hostWindow: NSWindow
        let startedAt: TimeInterval
        var loadState: LoadState
    }

    private var entries: [Entry] = []
    private let capacity: Int
    private let makeWebView: @MainActor (UUID, WKWebsiteDataStore) -> CmuxWebView
    private let startLoad: @MainActor (CmuxWebView, URLRequest) -> Void

    init(
        capacity: Int = 4,
        makeWebView: @escaping @MainActor (UUID, WKWebsiteDataStore) -> CmuxWebView = {
            profileID,
            websiteDataStore in
            BrowserPanel.makeWebView(
                profileID: profileID,
                websiteDataStore: websiteDataStore
            )
        },
        startLoad: @escaping @MainActor (CmuxWebView, URLRequest) -> Void = {
            webView,
            request in
            webView.applyBrowserUserAgentPolicy(for: request.url)
            webView.load(request)
        }
    ) {
        self.capacity = max(1, capacity)
        self.makeWebView = makeWebView
        self.startLoad = startLoad
    }

    var entryCount: Int { entries.count }
    var readyCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .finished = entry.loadState { count += 1 }
        }
    }

    func prewarmDefaultProfile() {
        let profileID = BrowserPanel.resolvedProfileID(requested: nil)
        prewarm(
            profileID: profileID,
            websiteDataStore: BrowserProfileStore.shared.websiteDataStore(for: profileID)
        )
    }

    func prewarm(profileID: UUID, websiteDataStore: WKWebsiteDataStore) {
        guard let launcherURL = CodeStaticURLSchemeHandler.launcherURL else { return }
        if entries.contains(where: {
            $0.profileID != profileID || $0.websiteDataStore !== websiteDataStore
        }) {
            discard(reason: "profile-changed")
        }
        guard entries.count < capacity,
              !entries.contains(where: {
                  if case .loading = $0.loadState { return true }
                  return false
              }) else {
            return
        }

        // Fill serially. Starting several WKWebView navigations together makes
        // the first frame compete for WebContent process startup and can push
        // its first paint beyond the interaction budget.
        let webView = makeWebView(profileID, websiteDataStore)
        webView.navigationDelegate = self
        let hostWindow = Self.makeHiddenHostWindow(for: webView)
        entries.append(
            Entry(
                webView: webView,
                profileID: profileID,
                websiteDataStore: websiteDataStore,
                hostWindow: hostWindow,
                startedAt: ProcessInfo.processInfo.systemUptime,
                loadState: .loading
            )
        )
        startLoad(webView, URLRequest(url: launcherURL))
#if DEBUG
        cmuxDebugLog(
            "code.warmer.start profile=\(profileID.uuidString.prefix(5)) " +
            "entries=\(entries.count)"
        )
#endif
    }

    /// Returns a finished inert first frame matching the panel. Loading
    /// entries stay in the pool so another panel can use them once complete.
    func claim(profileID: UUID, websiteDataStore: WKWebsiteDataStore) -> CmuxWebView? {
        // Prefer the newest completed frame. The oldest entry absorbs the
        // WebContent process startup cost, while later serial entries paint
        // against an already-warm process.
        guard let index = entries.lastIndex(where: {
            guard $0.profileID == profileID,
                  $0.websiteDataStore === websiteDataStore else {
                return false
            }
            if case .finished = $0.loadState { return true }
            return false
        }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        let webView = entry.webView
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        webView.browserPortalPrepareForHiddenHostAdoption()
        entry.hostWindow.close()
#if DEBUG
        cmuxDebugLog(
            "code.warmer.claim remaining=\(entries.count) ready=\(readyCount)"
        )
#endif
        return webView
    }

    func discard(reason: String) {
        let discardedEntries = entries
        entries.removeAll()
        for entry in discardedEntries {
            entry.webView.navigationDelegate = nil
            entry.webView.stopLoading()
            entry.webView.removeFromSuperview()
            entry.hostWindow.close()
        }
#if DEBUG
        if !discardedEntries.isEmpty {
            cmuxDebugLog(
                "code.warmer.discard reason=\(reason) count=\(discardedEntries.count)"
            )
        }
#endif
    }

    private static func makeHiddenHostWindow(for webView: WKWebView) -> NSWindow {
        var size = NSSize(width: 1080, height: 760)
        if let contentSize = NSApp.mainWindow?.contentView?.bounds.size,
           contentSize.width >= 320,
           contentSize.height >= 240 {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.codeWebViewWarmer")
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

    private func discard(webView: WKWebView, reason: String) {
        guard let index = entries.firstIndex(where: { $0.webView === webView }) else { return }
        let entry = entries.remove(at: index)
        entry.webView.navigationDelegate = nil
        entry.webView.stopLoading()
        entry.webView.removeFromSuperview()
        entry.hostWindow.close()
#if DEBUG
        cmuxDebugLog("code.warmer.discard reason=\(reason) count=1")
#endif
    }
}

extension CodeWebViewWarmer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let index = entries.firstIndex(where: { $0.webView === webView }) else { return }
        var entry = entries[index]
        entry.loadState = .finished
        entries[index] = entry
#if DEBUG
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - entry.startedAt) * 1_000
        )
        cmuxDebugLog(
            "code.warmer.ready elapsedMs=\(elapsedMilliseconds) " +
            "ready=\(readyCount)/\(entries.count)"
        )
#endif
        prewarm(
            profileID: entry.profileID,
            websiteDataStore: entry.websiteDataStore
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        discard(webView: webView, reason: "load-failed")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        discard(webView: webView, reason: "provisional-load-failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        discard(webView: webView, reason: "webcontent-terminated")
    }
}
