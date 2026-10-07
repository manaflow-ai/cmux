public import CmuxBrowserStream
public import Foundation

/// Which URLs a phone may load: http and https with a host, nothing else
/// (no `file`, `javascript`, `data`, `about`, `chrome` or app schemes).
public struct BrowserNavigationPolicy: Hashable, Sendable {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public init() {}

    /// The URL to load, or why it is refused.
    public func check(_ text: String) -> Result<URL, RbNavigateRefusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        guard Self.allowedSchemes.contains(scheme) else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }
}
