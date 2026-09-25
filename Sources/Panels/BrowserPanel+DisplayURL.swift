import Foundation
import CmuxCore

extension BrowserPanel {
    /// The displayed web page, excluding blank tabs and app-only URL schemes.
    var externalBrowserURL: URL? {
        guard let rawURL = preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    static func restorableDisplayURL(
        liveURL: URL?,
        currentURL: URL?,
        activeErrorPageDisplayURL: URL?
    ) -> URL? {
        restorableDisplayURLCandidate(for: activeErrorPageDisplayURL)
            ?? restorableDisplayURLCandidate(for: liveURL)
            ?? restorableDisplayURLCandidate(for: currentURL)
    }

    private static func restorableDisplayURLCandidate(for url: URL?) -> URL? {
        let displayURL = remoteProxyDisplayURL(for: url) ?? url
        guard !isBlankBrowserPageURL(displayURL) else { return nil }
        return displayURL
    }

    static func remoteProxyDisplayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return url }
        guard let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }
}
