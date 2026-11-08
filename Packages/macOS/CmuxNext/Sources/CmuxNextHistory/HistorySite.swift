public import Foundation

/// The site Forget Site… removes every page visit of (`history.site.remove`, `cmux history remove-site`).
public nonisolated enum HistorySite {
    /// A typed host, or the host of a typed address, lowercased; nil when the text names none.
    public static func host(_ text: String?) -> String? {
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = typed.contains("://") ? URL(string: typed)?.host() ?? "" : typed
        return host.isEmpty || host.contains(where: { $0.isWhitespace || $0 == "/" }) ? nil : host.lowercased()
    }

    /// Forget Site… without a site.
    public static var needsSite: String {
        String(localized: "history.refusal.needsSite", defaultValue: "Type a site, such as example.com", bundle: .module)
    }
}
