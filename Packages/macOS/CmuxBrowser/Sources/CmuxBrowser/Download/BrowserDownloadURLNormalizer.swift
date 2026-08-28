public import Foundation

/// Unwraps trusted Google redirect URLs before browser context-menu downloads.
///
/// Page-provided query items are untrusted and may repeat or differ only by
/// case. The first value wins so normalization is deterministic without using
/// a trapping unique-key dictionary initializer.
public struct BrowserDownloadURLNormalizer: Sendable {
    private static let supportedGoogleRegistrableDomains: Set<String> = [
        "google.com",
        "google.co.uk",
        "google.de",
        "google.fr",
        "google.ca",
        "google.com.au",
        "google.co.jp",
        "google.co.in",
        "google.com.br",
        "google.es",
        "google.it",
        "google.nl",
        "google.pl",
        "google.com.mx",
        "google.com.tr",
        "google.com.tw",
        "google.co.kr",
        "google.com.hk",
        "google.com.sg",
        "google.com.ar",
        "google.cl",
        "google.co.za",
    ]

    /// Creates a URL normalizer with the built-in Google-domain policy.
    public init() {}

    /// Returns the underlying downloadable target for a trusted Google
    /// redirect, or `url` unchanged when no valid target is present.
    ///
    /// - Parameter url: A URL captured from page content or browser navigation.
    /// - Returns: A normalized download URL, or the original URL.
    public func normalize(_ url: URL) -> URL {
        resolvedGoogleRedirectURL(url) ?? url
    }

    private func resolvedGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), Self.isSupportedGoogleHost(host) else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        // Query items come from arbitrary page URLs. Keep the first occurrence
        // after case-folding instead of trapping on duplicate keys.
        let map = Dictionary(
            queryItems.map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let candidate = URL(string: raw),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }

        // Some links are wrapped as /url?...; URLComponents has already
        // percent-decoded each query-item value, so do not decode it again.
        if components.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key],
                   let candidate = URL(string: raw),
                   isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func isSupportedGoogleHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return supportedGoogleRegistrableDomains.contains { domain in
            normalizedHost == domain || normalizedHost.hasSuffix("." + domain)
        }
    }

    private func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}
