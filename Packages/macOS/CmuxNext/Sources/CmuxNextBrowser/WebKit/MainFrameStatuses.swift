import Foundation
public import WebKit

/// The HTTP status of a tab's last main-frame response per URL
/// (`WebKitTab.mainFrameStatuses`), so a page restored from the back-forward
/// cache, which gets no new response, still has one. Automation reports it
/// as `Response.status()`.
@MainActor
public final class MainFrameStatuses {
    private var statuses: [URL: Int] = [:]

    public init() {}

    /// Records a response (WKNavigationDelegate); a non-HTTP one clears the
    /// URL's status.
    public func record(_ response: WKNavigationResponse) {
        guard response.isForMainFrame, let url = response.response.url else { return }
        if statuses.count >= 64 { statuses.removeAll() }
        statuses[url] = (response.response as? HTTPURLResponse)?.statusCode
    }

    /// The status of the last main-frame response for `url`.
    public func status(for url: URL) -> Int? {
        statuses[url]
    }
}
