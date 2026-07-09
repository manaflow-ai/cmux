public import Foundation

extension String {
    /// This string interpreted as omnibar / address-bar input, resolved to a
    /// navigable web URL, or `nil` when it should be treated as a search query
    /// instead of a navigation target.
    ///
    /// Mirrors the address-bar rules the embedded browser uses: localhost,
    /// loopback, and `*.localhost` hosts navigate over `http://`; explicit
    /// `http`/`https`/`file` URLs pass through; a dotted "scheme" followed by a
    /// numeric port is recognized as a bare `host:port` (because
    /// `URL(string: "example.com:8443")` otherwise parses `example.com` as the
    /// scheme); and inputs containing `:`, `/`, or `.` fall back to `https://`.
    /// Empty or whitespace-only input and input containing a space return `nil`.
    public var omnibarNavigableURL: URL? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(" ") else { return nil }

        // Check localhost/loopback before generic URL parsing because
        // URL(string: "localhost:3777") treats "localhost" as a scheme.
        let lower = trimmed.lowercased()
        let bareHost = lower.omnibarBareHostCandidate
        if lower.hasPrefix("localhost") ||
            lower.hasPrefix("127.0.0.1") ||
            lower.hasPrefix("[::1]") ||
            (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
            return URL(string: "http://\(trimmed)")
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return url
            }
            if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
                return url
            }
            // URL(string: "example.com:8443") parses "example.com" as the scheme.
            // No real scheme contains a dot, so a dotted "scheme" followed by a
            // numeric port is a bare host:port that must navigate, not search.
            if trimmed.isOmnibarDottedHostWithPort(schemeCandidate: scheme) {
                return URL(string: "https://\(trimmed)")
            }
            return nil
        }

        if trimmed.contains(":") || trimmed.contains("/") {
            return URL(string: "https://\(trimmed)")
        }

        if trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }

        return nil
    }

    /// The leading host portion of this already-lowercased input, up to the first
    /// `:`, `/`, `?`, or `#` (or the whole string when none is present). Used to
    /// detect `*.localhost` hosts before generic URL parsing.
    private var omnibarBareHostCandidate: String {
        let end = firstIndex { character in
            character == ":" || character == "/" || character == "?" || character == "#"
        } ?? endIndex
        return String(self[..<end])
    }

    /// Whether this input is a bare `host:port` whose host contains a dot, which
    /// `URL(string:)` otherwise misreads as a custom scheme. True when
    /// `schemeCandidate` (the scheme `URL(string:)` parsed) contains a dot and is
    /// immediately followed by `:`, a non-empty numeric port that fits in
    /// `UInt16`, and then nothing or a `/`, `?`, or `#`.
    private func isOmnibarDottedHostWithPort(schemeCandidate: String) -> Bool {
        guard schemeCandidate.contains(".") else { return false }
        guard count > schemeCandidate.count else { return false }
        let afterScheme = dropFirst(schemeCandidate.count)
        guard afterScheme.first == ":" else { return false }
        let portAndRest = afterScheme.dropFirst()
        let port = portAndRest.prefix(while: { $0.isNumber })
        guard !port.isEmpty, UInt16(port) != nil else { return false }
        let rest = portAndRest.dropFirst(port.count)
        return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
    }
}
