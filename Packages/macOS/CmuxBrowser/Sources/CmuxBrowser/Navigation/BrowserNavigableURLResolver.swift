public import Foundation

/// Resolves a raw omnibar string into a navigable `http`/`https`/`file` URL, or
/// `nil` when the input should be treated as a search query instead of a URL.
///
/// This is the omnibar's "is this a URL or a search?" decision. It is pure
/// Foundation string/URL parsing with no UI or WebKit dependency: it detects
/// localhost/loopback hosts before generic `URL(string:)` parsing (because
/// `URL(string: "localhost:3777")` mis-parses `localhost` as a scheme),
/// disambiguates a dotted `host:port` that `URL(string:)` would treat as a
/// scheme (no real scheme contains a dot), and validates the resulting scheme.
///
/// The AppKit/WebKit consumers (the omnibar commit path and the control-socket
/// browser navigation command) hold a resolver and call ``resolve(_:)`` to turn
/// typed text into a URL to load. Because the resolver carries no state, it is a
/// `Sendable` value type rather than a free-standing function.
public struct BrowserNavigableURLResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Returns the navigable URL for a raw omnibar input, or `nil` when the
    /// input is empty, contains a space, or does not look like a URL (and should
    /// therefore be handled as a search query).
    ///
    /// Resolution order:
    /// - Empty (after trimming) or space-containing input is not a URL.
    /// - `localhost`, `127.0.0.1`, `[::1]`, and `*.localhost` hosts navigate over
    ///   `http://`, checked first because `URL(string:)` mis-parses them.
    /// - A parseable `http`/`https` URL, or a `file:` URL with an absolute path,
    ///   navigates as-is.
    /// - A dotted `host:port` that `URL(string:)` mis-parses as a scheme
    ///   navigates over `https://`.
    /// - Otherwise, input containing `:`/`/` or a `.` navigates over `https://`.
    public func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(" ") else { return nil }

        // Check localhost/loopback before generic URL parsing because
        // URL(string: "localhost:3777") treats "localhost" as a scheme.
        let lower = trimmed.lowercased()
        let bareHost = bareHostCandidate(lower)
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
            if dottedHostWithPortCandidate(trimmed, schemeCandidate: scheme) {
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

    /// Returns the bare host prefix of a lowercased input, up to the first
    /// `:`, `/`, `?`, or `#` delimiter.
    private func bareHostCandidate(_ lowercasedInput: String) -> String {
        let end = lowercasedInput.firstIndex { character in
            character == ":" || character == "/" || character == "?" || character == "#"
        } ?? lowercasedInput.endIndex
        return String(lowercasedInput[..<end])
    }

    /// Returns whether `input` is a dotted `host:port[/...]` that `URL(string:)`
    /// mis-parsed as `schemeCandidate`. True only when the candidate scheme
    /// contains a dot, is immediately followed by a numeric port that fits in a
    /// `UInt16`, and the remainder is empty or starts with `/`, `?`, or `#`.
    private func dottedHostWithPortCandidate(_ input: String, schemeCandidate: String) -> Bool {
        guard schemeCandidate.contains(".") else { return false }
        guard input.count > schemeCandidate.count else { return false }
        let afterScheme = input.dropFirst(schemeCandidate.count)
        guard afterScheme.first == ":" else { return false }
        let portAndRest = afterScheme.dropFirst()
        let port = portAndRest.prefix(while: { $0.isNumber })
        guard !port.isEmpty, UInt16(port) != nil else { return false }
        let rest = portAndRest.dropFirst(port.count)
        return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
    }
}
