public import Foundation

/// The site Forget Site… removes every page visit of (`history.site.remove`, `cmux history remove-site`).
public nonisolated struct HistorySite: Hashable, Sendable {
    /// The site's host, lowercased.
    public let host: String

    /// A typed host, or the host of a typed address; nil when the text names none.
    public init?(_ text: String?) {
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = typed.contains("://") ? URL(string: typed)?.host() ?? "" : typed
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        self.host = host.lowercased()
    }

    /// Forget Site… without a site.
    public static var needsSite: String {
        String(localized: "history.refusal.needsSite", defaultValue: "Type a site, such as example.com", bundle: .module)
    }
}
