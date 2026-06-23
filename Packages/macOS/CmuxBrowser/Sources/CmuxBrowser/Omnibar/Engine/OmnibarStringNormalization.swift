import Foundation

/// URL/scheme string normalization helpers the omnibar suggestion engine uses
/// to compare typed text against candidate URLs.
///
/// These live as `String` members (not free functions) so call sites read as
/// `value.omnibarSchemeStripped`; the optionality stays at the call site.
public extension String {
    /// The receiver, trimmed and lowercased, with a leading `http://`/`https://`
    /// scheme removed.
    var omnibarSchemeStripped: String {
        var normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        return normalized
    }

    /// The receiver with a leading scheme and a leading `www.` removed, trimmed
    /// and lowercased.
    var omnibarSchemeAndWWWStripped: String {
        var normalized = omnibarSchemeStripped
        if normalized.hasPrefix("www.") {
            normalized.removeFirst("www.".count)
        }
        return normalized
    }

    /// The receiver normalized for prefix/substring scoring: when it parses as a
    /// URL, host (without `www.`), non-default port, path, query, and fragment;
    /// otherwise the scheme-and-`www`-stripped form.
    var omnibarScoringCandidate: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let components = URLComponents(string: trimmed), let host = components.host?.lowercased() {
            let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let normalizedScheme = components.scheme?.lowercased()
            let isDefaultPort = (normalizedScheme == "http" && components.port == 80)
                || (normalizedScheme == "https" && components.port == 443)
            let portSuffix = {
                guard let port = components.port, !isDefaultPort else { return "" }
                return ":\(port)"
            }()

            var normalized = "\(hostWithoutWWW)\(portSuffix)"
            let path = components.percentEncodedPath
            if !path.isEmpty && path != "/" {
                normalized += path
            } else if path == "/" {
                normalized += "/"
            }

            if let query = components.percentEncodedQuery, !query.isEmpty {
                normalized += "?\(query)"
            }
            if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
                normalized += "#\(fragment)"
            }
            return normalized
        }

        return trimmed.omnibarSchemeAndWWWStripped
    }

    /// The receiver as a single-character query (trimmed, lowercased) when it is
    /// exactly one UTF-16 unit long, otherwise `nil`.
    var omnibarSingleCharacterQuery: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.utf16.count == 1 else { return nil }
        return trimmed
    }

    /// The receiver with its trailing word removed using Foundation word
    /// boundaries, preserving the prefix exactly (used for word-delete).
    var omnibarPrefixAfterDeletingTrailingWord: String {
        let nsText = self as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var deletionStart = nsText.length
        nsText.enumerateSubstrings(in: fullRange, options: [.byWords, .reverse]) { _, range, _, stop in
            deletionStart = range.location
            stop.pointee = true
        }
        return nsText.substring(to: deletionStart)
    }
}
