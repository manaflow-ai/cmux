public import Foundation

#if DEBUG
internal import CMUXDebugLog
#endif

/// Owns the favicon-refresh state machine for one `BrowserPanel`: the refresh
/// generation counter, the in-flight refresh `Task`, and the last fetched icon
/// URL used to skip redundant refetches. Pure sequencing logic; every effect on
/// the live `WKWebView`, the remote-proxy `URLSession`, or the panel's
/// `@Published` favicon bytes is forwarded to the app-side ``BrowserFaviconHosting``.
///
/// The refresh flow discovers the best `<link rel="icon">` URL by evaluating the
/// page script (retrying once after 600 ms for SPAs that inject the tag late),
/// falls back to `/favicon.ico`, fetches the bytes through the host, renders them
/// to a square PNG with ``BrowserFaviconImageRenderer``, and publishes the
/// result. Every await point re-checks the captured web-view instance id and the
/// refresh generation so a navigation or web-view swap cancels stale work.
///
/// `@MainActor` because the panel that owns it is `@MainActor` and every entry
/// point runs on a main-actor WebKit navigation turn.
@MainActor
public final class BrowserFaviconCoordinator {
    /// The app-side host that performs the favicon effects. Weak because the host
    /// (`BrowserPanel`) owns this coordinator strongly and outlives it, so this is
    /// non-nil whenever a method runs.
    public weak var host: (any BrowserFaviconHosting)?

    /// The owning panel's id, used only to name the `#if DEBUG` favicon logs.
    private let panelID: UUID

    /// The in-flight favicon refresh, cancelled when a new load or refresh starts.
    private var faviconTask: Task<Void, Never>?

    /// Monotonic refresh generation. Bumped on every new load/refresh so an await
    /// resuming after the page changed can detect that it is stale and bail.
    private var faviconRefreshGeneration: Int = 0

    /// The last icon URL whose PNG was fetched, used to skip a redundant refetch
    /// when the discovered icon URL is unchanged and a PNG is already published.
    private var lastFaviconURLString: String?

    /// - Parameter panelID: The owning panel's id, used only for debug-log naming.
    public init(panelID: UUID) {
        self.panelID = panelID
    }

    /// Discovers and fetches the favicon for the current page, then publishes a
    /// rendered PNG through the host. Cancels any in-flight refresh first.
    public func refreshFavicon() {
        faviconTask?.cancel()
        faviconTask = nil

        guard let host else { return }
        guard let pageURL = host.currentFaviconPageURL else { return }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        faviconRefreshGeneration &+= 1
        let refreshGeneration = faviconRefreshGeneration
        let refreshWebViewInstanceID = host.currentFaviconWebViewInstanceID

        faviconTask = Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            guard host.isCurrentFaviconWebView(instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.begin " +
                "panel=\(self.panelID.uuidString.prefix(5)) " +
                "page=\(pageURL.absoluteString)"
            )
#endif

            // Try to discover the best icon URL from the document.
            let discoveryScript = BrowserFaviconDiscoveryScript()

            var discoveredURL: URL?
            if let href = await host.evaluateFaviconDiscoveryScript() {
                discoveredURL = discoveryScript.parse(href: href)
            }
            guard host.isCurrentFaviconWebView(instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            // SPAs often inject <link rel="icon"> via JavaScript after the initial
            // HTML loads. If no link tag was found, wait briefly and retry once to
            // give client-side scripts time to add the tag.
            if discoveredURL == nil {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard host.isCurrentFaviconWebView(instanceID: refreshWebViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
                if let href = await host.evaluateFaviconDiscoveryScript() {
                    discoveredURL = discoveryScript.parse(href: href)
                }
                guard host.isCurrentFaviconWebView(instanceID: refreshWebViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
            }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.iconURL " +
                "panel=\(self.panelID.uuidString.prefix(5)) " +
                "discovered=\(discoveredURL?.absoluteString ?? "<nil>") " +
                "fallback=\(fallbackURL?.absoluteString ?? "<nil>") " +
                "chosen=\(iconURL.absoluteString)"
            )
#endif

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == self.lastFaviconURLString, host.hasFaviconPNGData {
#if DEBUG
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.skipCached " +
                    "panel=\(self.panelID.uuidString.prefix(5)) " +
                    "icon=\(iconURLString)"
                )
#endif
                return
            }
            self.lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(String.safariDesktopUserAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, response) = await host.fetchFaviconData(request: req) else { return }
            guard host.isCurrentFaviconWebView(instanceID: refreshWebViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
#if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.badResponse " +
                    "panel=\(self.panelID.uuidString.prefix(5)) " +
                    "status=\(status)"
                )
#endif
                return
            }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.response " +
                "panel=\(self.panelID.uuidString.prefix(5)) " +
                "status=\(http.statusCode) " +
                "bytes=\(data.count)"
            )
#endif

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = BrowserFaviconImageRenderer().pngData(from: data, targetPx: 32) else {
#if DEBUG
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.decodeFailed " +
                    "panel=\(self.panelID.uuidString.prefix(5)) " +
                    "bytes=\(data.count)"
                )
#endif
                return
            }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            host.publishFaviconPNG(png)
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.ready " +
                "panel=\(self.panelID.uuidString.prefix(5)) " +
                "pngBytes=\(png.count)"
            )
#endif
        }
    }

    /// Whether the favicon refresh for `generation` is still the current one and
    /// its task has not been cancelled.
    public func isCurrentFaviconRefresh(generation: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation == faviconRefreshGeneration
    }

    /// Cancels any in-flight refresh and invalidates the generation so a later
    /// await bails (legacy `faviconTask?.cancel(); faviconTask = nil;
    /// faviconRefreshGeneration &+= 1`).
    public func cancelInFlightRefreshInvalidatingGeneration() {
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
    }

    /// Cancels any in-flight refresh without bumping the generation (legacy
    /// `faviconTask?.cancel(); faviconTask = nil`).
    public func cancelInFlightRefresh() {
        faviconTask?.cancel()
        faviconTask = nil
    }

    /// Invalidates the refresh for a freshly started page load: bumps the
    /// generation, cancels the in-flight refresh, and clears the cached icon URL
    /// (legacy load-changed reset).
    public func invalidateRefreshForNewLoad() {
        faviconRefreshGeneration &+= 1
        faviconTask?.cancel()
        faviconTask = nil
        lastFaviconURLString = nil
    }

    /// Clears the cached last-fetched icon URL so the next refresh refetches even
    /// for the same URL (legacy `lastFaviconURLString = nil`).
    public func clearLastFaviconURLString() {
        lastFaviconURLString = nil
    }
}
