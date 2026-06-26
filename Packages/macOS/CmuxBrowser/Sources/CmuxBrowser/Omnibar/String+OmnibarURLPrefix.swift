import Foundation

extension String {
    /// This string trimmed and lowercased with any leading `http://`/`https://`
    /// scheme removed. Used to compare omnibar completions against typed text
    /// regardless of scheme.
    public var strippingHTTPSchemePrefix: String {
        var normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        return normalized
    }

    /// This string after `strippingHTTPSchemePrefix` with a leading `www.` also
    /// removed.
    public var strippingHTTPSchemeAndWWWPrefix: String {
        var normalized = strippingHTTPSchemePrefix
        if normalized.hasPrefix("www.") {
            normalized.removeFirst("www.".count)
        }
        return normalized
    }
}
