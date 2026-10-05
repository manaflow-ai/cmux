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
                guard let self else { return false }
                enqueuePrompt(.permission(.automaticDownloads), origin: site, completion: answer)
                return true
            }
        )
    }

    /// Asks the gate for a navigation that becomes a download.
    func admitDownload(decide: @escaping (Bool) -> Void) {
        automaticDownloads.request(site: pageSite) { decide($0 == .allowed) }
    }

    /// The origin of the page the tab shows (asked before a navigation
    /// starts, so it is still the page that asked for it); nil for an
    /// opaque origin (data:, about:blank). Chromium uses its tab's last
    /// committed page the same way.
    var pageSite: String? {
        webView.url.flatMap(PageInfoSite.origin(of:))
    }
}
