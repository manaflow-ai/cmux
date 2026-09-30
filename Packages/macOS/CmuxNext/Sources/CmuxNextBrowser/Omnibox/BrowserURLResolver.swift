public import Foundation

/// Decides whether address bar text is a URL to load or a search query.
///
/// Rules, in order:
/// 1. Line breaks and tabs from a wrapped terminal paste are removed only
///    when the break comes after the URL's authority (host) has ended, so
///    `https://example.com/very/\nlong/path` loads while `example.\ncom`
///    searches.
/// 2. Explicit `http`, `https`, `file`, and `about:blank` load; with
///    `allowsChromiumSchemes` (Chromium tabs) also `chrome://` WebUI and
///    `chrome-extension://` pages. Every other scheme (`javascript:`,
///    `data:`, `mailto:`, ...) is searched, so typed text can never run
///    script or open another app.
/// 3. `/abs/path`, `~`, and `~/path` are file URLs, spaces allowed.
/// 4. Remaining text with whitespace is a search.
/// 5. Scheme-less text: userinfo (`user@host`) is refused, loopback hosts
///    get `http`, dotted hosts or hosts with a port get `https`, and single
///    words search.
public nonisolated struct BrowserURLResolver: Sendable {
    private let homeDirectory: URL
    public var allowsChromiumSchemes: Bool

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, allowsChromiumSchemes: Bool = false) {
        self.homeDirectory = homeDirectory
        self.allowsChromiumSchemes = allowsChromiumSchemes
    }

    /// A URL to load, or nil when the text should be searched.
    public func url(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let text = removingWrapBreaks(trimmed) else { return nil }

        if let fileURL = fileURL(for: text) {
            return fileURL
        }
        guard !text.contains(where: \.isWhitespace) else { return nil }

        if let scheme = explicitScheme(of: text) {
            return explicitURL(text, scheme: scheme)
        }
        return schemeLessURL(text)
    }

    // MARK: Wrapped paste

    /// Returns the text with wrap breaks removed, the text unchanged when it
    /// has none, or nil when a break sits inside what would be the host.
    private func removingWrapBreaks(_ text: String) -> String? {
        guard let firstBreak = text.firstIndex(where: Self.isWrapBreak) else { return text }
        let authorityStart = text.range(of: "://")?.upperBound ?? text.startIndex
        guard authorityStart <= firstBreak,
              let authorityEnd = text[authorityStart...].firstIndex(where: { "/?#".contains($0) }),
              authorityEnd < firstBreak else {
            return nil
        }
        let compacted = text.filter { !Self.isWrapBreak($0) }
        return compacted.contains(where: \.isWhitespace) ? nil : compacted
    }

    private static func isWrapBreak(_ character: Character) -> Bool {
        character.isNewline || character == "\t"
    }

    // MARK: Files

    private func fileURL(for text: String) -> URL? {
        if text.hasPrefix("/") {
            return URL(filePath: text)
        }
        if text == "~" {
            return URL(filePath: homeDirectory.path(percentEncoded: false), directoryHint: .isDirectory)
        }
        if text.hasPrefix("~/") {
            return homeDirectory.appending(path: String(text.dropFirst(2)))
        }
        return nil
    }

    // MARK: Explicit schemes

    /// The scheme when the text starts with one. `localhost:3000` and
    /// `example.com:8080/x` are host-and-port, not schemes.
    private func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
            return nil
        }
        let afterColon = text[text.index(after: colon)...]
        let port = afterColon.prefix { $0.isNumber }
        if !port.isEmpty, !afterColon.hasPrefix("//") {
            let rest = afterColon.dropFirst(port.count)
            if rest.isEmpty || "/?#".contains(rest.first!) {
                return nil
            }
        }
        return candidate.lowercased()
    }

    private func explicitURL(_ text: String, scheme: String) -> URL? {
        switch scheme {
        case "http", "https":
            guard let components = URLComponents(string: text),
                  let host = components.host, !host.isEmpty else {
                return nil
            }
            return components.url
        case "file":
            guard let url = URL(string: text), url.isFileURL, url.path().hasPrefix("/") else { return nil }
            return url
        case "about":
            return text.lowercased() == "about:blank" ? URL(string: "about:blank") : nil
        case "chrome", "chrome-extension":
            guard allowsChromiumSchemes, let components = URLComponents(string: text),
                  let host = components.host, !host.isEmpty else { return nil }
            return components.url
        default:
            return nil
        }
    }

    // MARK: Scheme-less

    private func schemeLessURL(_ text: String) -> URL? {
        let authorityEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let authority = text[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        let (host, hasPort) = Self.splitHostAndPort(authority)
        guard !host.isEmpty else { return nil }

        let scheme: String
        if Self.isLoopback(host) {
            scheme = "http"
        } else if hasPort || Self.isDottedHost(host) {
            scheme = "https"
        } else {
            return nil
        }
        guard let components = URLComponents(string: "\(scheme)://\(text)"),
              components.host?.isEmpty == false else {
            return nil
        }
        return components.url
    }

    /// Lowercased host (brackets stripped from IPv6) and whether a numeric
    /// port follows it. A non-numeric "port" yields an empty host.
    static func splitHostAndPort(_ authority: Substring) -> (host: String, hasPort: Bool) {
        let lower = authority.lowercased()
        if lower.hasPrefix("[") {
            guard let close = lower.firstIndex(of: "]") else { return ("", false) }
            let host = String(lower[lower.index(after: lower.startIndex)..<close])
            let rest = lower[lower.index(after: close)...]
            if rest.isEmpty { return (host, false) }
            guard rest.hasPrefix(":"), isPort(rest.dropFirst()) else { return ("", false) }
            return (host, true)
        }
        guard let colon = lower.firstIndex(of: ":") else { return (lower, false) }
        guard isPort(lower[lower.index(after: colon)...]) else { return ("", false) }
        return (String(lower[..<colon]), true)
    }

    private static func isPort(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isNumber) && UInt16(text) != nil
    }

    /// `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, and `0.0.0.0`.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// A host with at least two labels whose last label looks like a TLD
    /// (letters, or a numeric IPv4 address).
    private static func isDottedHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            return true
        }
        guard let tld = labels.last, tld.count >= 2 else { return false }
        return tld.allSatisfy { $0.isLetter } || tld.hasPrefix("xn--")
    }
}
