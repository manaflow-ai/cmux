import Foundation

/// Normalizes page-derived URLs before browser context-menu downloads use them.
struct BrowserDownloadURLNormalizer {
    func normalize(_ url: URL) -> URL {
        resolvedGoogleRedirectURL(url) ?? url
    }

    private func resolvedGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        // Query items are page-controlled and may repeat or differ only by case.
        let map = Dictionary(
            queryItems.map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if components.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}
