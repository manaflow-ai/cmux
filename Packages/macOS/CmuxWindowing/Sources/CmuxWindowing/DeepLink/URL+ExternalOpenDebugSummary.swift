public import Foundation

extension URL {
    /// A compact `scheme:target:queryNames` summary of this URL for the
    /// external-open (`application(_:open:)`) DEBUG diagnostics.
    ///
    /// `target` is the host, falling back to the slash-trimmed path; the query
    /// segment lists the query item names. Empty components render as `nil`
    /// (target) or `none` (query). Pure URL string work with no main-bound
    /// dependency, so it is `nonisolated`; the app target maps it over the
    /// opened URLs inside its `#if DEBUG` `AuthDebugLog` trail.
    public var externalOpenDebugSummary: String {
        let scheme = scheme ?? "nil"
        let target = host ?? path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name)
            .joined(separator: ",") ?? ""
        return "\(scheme):\(target.isEmpty ? "nil" : target):\(queryItems.isEmpty ? "none" : queryItems)"
    }
}
