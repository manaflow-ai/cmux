import Foundation

extension String {
    /// This query trimmed and lowercased when it is exactly one UTF-16 unit long,
    /// or `nil` for empty or multi-character queries. Drives the single-letter
    /// omnibar matching path that filters history and open-tab suggestions by a
    /// one-character prefix.
    public var omnibarSingleCharacterQuery: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.utf16.count == 1 else { return nil }
        return trimmed
    }

    /// This value normalized to the host/port/path/query/fragment form used when
    /// scoring an omnibar candidate against the typed query: the `www.` prefix and
    /// default ports are dropped, paths and queries are preserved percent-encoded.
    /// Falls back to scheme/`www.` stripping when the value has no parseable host.
    public var omnibarScoringCandidate: String {
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

        return trimmed.strippingHTTPSchemeAndWWWPrefix
    }
}
