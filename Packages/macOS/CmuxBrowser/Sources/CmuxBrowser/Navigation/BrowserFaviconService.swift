public import Foundation
import AppKit
internal import CMUXDebugLog

/// Discovers, fetches, decodes, and validates a page's favicon for a browser panel.
///
/// `BrowserFaviconService` is the side-effecting capability behind a browser
/// panel's tab/sidebar icon. Given the committed page URL it:
///
/// 1. runs an icon-discovery script (``iconURLDiscoveryScript``) through the
///    injected ``BrowserFaviconScriptEvaluating`` seam to score the page's
///    `<link rel="icon">` tags and pick the largest, retrying once after a short
///    delay because SPAs inject the link after the initial HTML;
/// 2. falls back to `/favicon.ico` relative to the page when no link is found;
/// 3. de-dupes against the last fetched icon URL so a same-URL reload does not
///    re-fetch when an icon is already in hand;
/// 4. fetches the icon (through the panel's remote-workspace proxy when one is
///    active), requires an HTTP 2xx response, and decodes it into a normalized
///    32px aspect-fit PNG via ``NSImage/faviconPNGData(targetPx:)``;
/// 5. hands the validated PNG back to the panel, which owns the published
///    `faviconPNGData` state.
///
/// It owns the in-flight task, a monotonic refresh generation, and the
/// last-fetched icon URL; it owns no UI state and never touches the web view,
/// the window, or panel focus directly (all page access goes through the seam).
/// It is `@MainActor` because the seam's WebKit evaluation and AppKit favicon
/// decode are main-thread only and the generation/identity guards run
/// synchronously between `await` points.
@MainActor
public final class BrowserFaviconService {
    private let evaluator: any BrowserFaviconScriptEvaluating
    private var faviconTask: Task<Void, Never>?
    private var faviconRefreshGeneration: Int = 0
    private var lastFaviconURLString: String?

    /// Creates a favicon service bound to a page/proxy evaluator.
    /// - Parameter evaluator: The seam that evaluates discovery scripts and exposes
    ///   the panel's web-view identity and remote-proxy inputs.
    public init(evaluator: any BrowserFaviconScriptEvaluating) {
        self.evaluator = evaluator
    }

    /// The JavaScript that finds the best icon URL declared in the document.
    ///
    /// It collects every `<link>` that declares an icon relation, scores each by
    /// the largest dimension in its `sizes` attribute (`any` scores highest),
    /// sorts descending, and returns the top candidate's resolved `href` (or the
    /// empty string when the document declares none).
    public static let iconURLDiscoveryScript = """
    (() => {
      const links = Array.from(document.querySelectorAll(
        'link[rel~=\"icon\"], link[rel=\"shortcut icon\"], link[rel=\"apple-touch-icon\"], link[rel=\"apple-touch-icon-precomposed\"]'
      ));
      function score(link) {
        const v = (link.sizes && link.sizes.value) ? link.sizes.value : '';
        if (v === 'any') return 1000;
        let max = 0;
        for (const part of v.split(/\\s+/)) {
          const m = part.match(/(\\d+)x(\\d+)/);
          if (!m) continue;
          const a = parseInt(m[1], 10);
          const b = parseInt(m[2], 10);
          if (Number.isFinite(a)) max = Math.max(max, a);
          if (Number.isFinite(b)) max = Math.max(max, b);
        }
        return max;
      }
      links.sort((a, b) => score(b) - score(a));
      return links[0]?.href || '';
    })();
    """

    /// Cancels any in-flight favicon refresh and invalidates its generation.
    ///
    /// The panel calls this when it tears down or replaces the web view so a stale
    /// fetch can never assign an icon for an abandoned page. Bumping the generation
    /// makes the abandoned task's guards (``isCurrentFaviconRefresh(generation:)``)
    /// fail even if it was past its last cancellation check.
    public func cancel() {
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
    }

    /// Cancels the in-flight refresh and clears the last-fetched icon URL so the
    /// next refresh re-fetches even for the same URL.
    ///
    /// The panel calls this when a new load begins (the previous page's favicon is
    /// cleared by the panel, so the dedup must not skip the re-fetch).
    public func resetForNewLoad() {
        cancel()
        lastFaviconURLString = nil
    }

    /// Clears only the last-fetched icon URL so the next refresh re-fetches, without
    /// cancelling any in-flight refresh.
    ///
    /// The panel calls this on a failed navigation (where it also clears the
    /// published favicon) so a later same-URL load is not skipped by the dedup; it
    /// must not disturb an in-flight task, matching the original failed-load path.
    public func clearLastFetchedIconURL() {
        lastFaviconURLString = nil
    }

    /// Starts a favicon refresh for `pageURL` and assigns the validated PNG via
    /// `assignFaviconPNGData` when one is produced.
    ///
    /// No-op for non-`http(s)` pages. The refresh runs as a cancellable task: it
    /// discovers the icon URL through the seam, de-dupes against the last fetch
    /// (skipping when the URL is unchanged and `currentFaviconPNGData()` already
    /// has an icon), fetches and decodes it, and on success calls
    /// `assignFaviconPNGData`. The current favicon is left untouched on any
    /// failure so the icon never flashes to empty.
    /// - Parameters:
    ///   - pageURL: The committed page URL whose favicon to refresh.
    ///   - webViewInstanceID: Identity of the live web view; re-checked between
    ///     `await` points so a profile/web-view swap abandons this refresh.
    ///   - panelIDPrefix: Short panel id prefix for debug logging only.
    ///   - currentFaviconPNGData: Reads the panel's current favicon for the
    ///     skip-cached check.
    ///   - assignFaviconPNGData: Receives the validated PNG to publish.
    public func refresh(
        pageURL: URL,
        webViewInstanceID: UUID,
        panelIDPrefix: String,
        currentFaviconPNGData: @escaping @MainActor () -> Data?,
        assignFaviconPNGData: @escaping @MainActor (Data) -> Void
    ) {
        faviconTask?.cancel()
        faviconTask = nil

        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        faviconRefreshGeneration &+= 1
        let refreshGeneration = faviconRefreshGeneration

        faviconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.evaluator.isCurrentWebView(instanceID: webViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.begin " +
                "panel=\(panelIDPrefix) " +
                "page=\(pageURL.absoluteString)"
            )
#endif

            // Try to discover the best icon URL from the document.
            let js = Self.iconURLDiscoveryScript

            var discoveredURL: URL?
            if let href = await self.evaluator.evaluateJavaScriptString(
                js,
                timeoutNanoseconds: 400_000_000
            ) {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let u = URL(string: trimmed) {
                    discoveredURL = u
                }
            }
            guard self.evaluator.isCurrentWebView(instanceID: webViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            // SPAs often inject <link rel="icon"> via JavaScript after the initial
            // HTML loads. If no link tag was found, wait briefly and retry once to
            // give client-side scripts time to add the tag.
            if discoveredURL == nil {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.evaluator.isCurrentWebView(instanceID: webViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
                if let href = await self.evaluator.evaluateJavaScriptString(
                    js,
                    timeoutNanoseconds: 400_000_000
                ) {
                    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let u = URL(string: trimmed) {
                        discoveredURL = u
                    }
                }
                guard self.evaluator.isCurrentWebView(instanceID: webViewInstanceID) else { return }
                guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }
            }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.iconURL " +
                "panel=\(panelIDPrefix) " +
                "discovered=\(discoveredURL?.absoluteString ?? "<nil>") " +
                "fallback=\(fallbackURL?.absoluteString ?? "<nil>") " +
                "chosen=\(iconURL.absoluteString)"
            )
#endif

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == self.lastFaviconURLString, currentFaviconPNGData() != nil {
#if DEBUG
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.skipCached " +
                    "panel=\(panelIDPrefix) " +
                    "icon=\(iconURLString)"
                )
#endif
                return
            }
            self.lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(BrowserUserAgent.safari, forHTTPHeaderField: "User-Agent")
            let effectiveRequest = self.evaluator.remoteProxyPreparedRequest(from: req)

            let data: Data
            let response: URLResponse
            do {
                let remoteSession = self.evaluator.remoteProxyEndpoint.flatMap {
                    BrowserRemoteProxyURLResolver().urlSession(for: $0)
                }
                defer { remoteSession?.finishTasksAndInvalidate() }
                if let remoteSession {
#if DEBUG
                    CMUXDebugLog.logDebugEvent(
                        "browser.favicon.fetch " +
                        "panel=\(panelIDPrefix) " +
                        "via=proxy " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await remoteSession.data(for: effectiveRequest)
                } else {
#if DEBUG
                    CMUXDebugLog.logDebugEvent(
                        "browser.favicon.fetch " +
                        "panel=\(panelIDPrefix) " +
                        "via=direct " +
                        "url=\(effectiveRequest.url?.absoluteString ?? "<nil>")"
                    )
#endif
                    (data, response) = try await URLSession.shared.data(for: effectiveRequest)
                }
            } catch {
#if DEBUG
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.fetchError " +
                    "panel=\(panelIDPrefix) " +
                    "error=\(String(describing: error))"
                )
#endif
                return
            }
            guard self.evaluator.isCurrentWebView(instanceID: webViewInstanceID) else { return }
            guard self.isCurrentFaviconRefresh(generation: refreshGeneration) else { return }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
#if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.badResponse " +
                    "panel=\(panelIDPrefix) " +
                    "status=\(status)"
                )
#endif
                return
            }
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.response " +
                "panel=\(panelIDPrefix) " +
                "status=\(http.statusCode) " +
                "bytes=\(data.count)"
            )
#endif

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = NSImage(data: data)?.faviconPNGData(targetPx: 32) else {
#if DEBUG
                CMUXDebugLog.logDebugEvent(
                    "browser.favicon.decodeFailed " +
                    "panel=\(panelIDPrefix) " +
                    "bytes=\(data.count)"
                )
#endif
                return
            }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            assignFaviconPNGData(png)
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.favicon.ready " +
                "panel=\(panelIDPrefix) " +
                "pngBytes=\(png.count)"
            )
#endif
        }
    }

    /// Returns whether the in-flight refresh for `generation` is still current.
    ///
    /// Mirrors the panel's original guard: a cancelled task or a superseded
    /// generation (a newer refresh started, or ``cancel()``/``resetForNewLoad()``
    /// ran) is no longer current.
    /// - Parameter generation: The refresh generation captured when the task began.
    /// - Returns: `true` when the task is not cancelled and still owns the latest
    ///   generation.
    private func isCurrentFaviconRefresh(generation: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation == faviconRefreshGeneration
    }
}
