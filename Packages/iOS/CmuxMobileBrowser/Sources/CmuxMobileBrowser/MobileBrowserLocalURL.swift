public import Foundation

/// URL helpers for the in-memory local browser resource scheme.
public enum MobileBrowserLocalURL {
    /// The private scheme registered only on cmux's local WebKit instance.
    public static let scheme = "cmux-local"

    /// Creates a local resource URL for one panel and logical path.
    public static func make(panelID: String, path: String) -> URL? {
        guard !panelID.isEmpty, path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = panelID
        components.percentEncodedPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? path
        return components.url
    }

    /// Returns the panel and logical path encoded in a local URL.
    public static func components(from url: URL) -> (panelID: String, path: String)? {
        guard url.scheme?.lowercased() == scheme,
              let panelID = url.host,
              !panelID.isEmpty else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        guard path.hasPrefix("/") else { return nil }
        return (panelID, path)
    }
}
