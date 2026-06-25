public import Foundation

extension URL {
    /// A privacy-redacted single-line rendering of this URL for debug logs.
    ///
    /// Strips userinfo (user/password), query, and fragment, keeping only the
    /// scheme, host, and path. Pure value-in/value-out: it never reaches into
    /// app state. Optionality lives at the call site
    /// (`maybeURL?.debugRedactedString ?? "nil"`).
    ///
    /// Returns `"<invalid>"` when the URL cannot be parsed into components, and
    /// `"<redacted>"` when the redacted components cannot be re-serialized.
    public var debugRedactedString: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<redacted>"
    }

    /// A compact `scheme:target:queryNames` summary of this URL for auth debug logs.
    ///
    /// `target` is the host, falling back to the slash-trimmed path. Only query
    /// parameter *names* are included (never values), so no secrets leak. Pure
    /// value-in/value-out with no app-state reach. Empty target renders `nil`
    /// and absent query parameters render `none`.
    public var authDebugSummary: String {
        let scheme = self.scheme ?? "nil"
        let target = host ?? path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name)
            .joined(separator: ",") ?? ""
        return "\(scheme):\(target.isEmpty ? "nil" : target):\(queryItems.isEmpty ? "none" : queryItems)"
    }
}
