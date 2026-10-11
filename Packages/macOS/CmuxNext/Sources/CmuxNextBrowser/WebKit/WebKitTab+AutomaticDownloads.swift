import Foundation
import WebKit

/// WebKit side of Chrome's automatic-downloads rule (`AutomaticDownloadGate`).
/// WebKit's public API carries no user gesture for a navigation or a
/// download (`WKNavigationAction` has none; `_isUserInitiated` is private),
/// so the gesture is the user's own input on the web view
/// (`WebKitWebView`: mouse down, key down) or a load cmux starts, as for
/// Chromium. A download counts for the site of the page the tab shows.
extension WebKitTab {
    func makeAutomaticDownloadGate() -> AutomaticDownloadGate {
        let profile = profileID
        return AutomaticDownloadGate(
            permissions: { [weak self] in (self?.pageInfoSettings ?? .shared).permissions(for: profile) },
            ask: { [weak self] site, answer in
                // Fail closed: a tab that is closed or in no window cannot
                // show the prompt bar, so nothing waits for it.
                guard let self, !isClosed, contentView.window != nil else { return false }
                enqueuePrompt(.permission(.automaticDownloads), origin: site, completion: answer)
                return true
            }
        )
    }

    /// Asks the gate for a navigation that becomes a download.
    func admitDownload(_ url: URL?, decide: @escaping (Bool) -> Void) {
        admitDownload(url, site: pageSite, decide: decide)
    }

    /// Asks the gate for a download of `url` counted for `site`; a refused
    /// one is listed blocked with `site` (`BrowserDownload.Status.blocked`).
    func admitDownload(_ url: URL?, site: String?, decide: @escaping (Bool) -> Void) {
        automaticDownloads.request(site: site) { [weak self] outcome in
            if let reason = AutomaticDownloadGate.blockedReason(outcome) {
                self?.emit(.download(.blocked(sourceURL: url, suggestedName: url?.lastPathComponent ?? "", site: site, reason: reason)))
            }
            decide(outcome == .allowed)
        }
    }

    /// The origin of the page the tab shows (asked before a navigation
    /// starts, so it is still the page that asked for it); nil for an
    /// opaque origin (data:, about:blank). Chromium uses its tab's last
    /// committed page the same way.
    var pageSite: String? {
        webView.url.flatMap(PageInfoSite.origin(of:))
    }
}
