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
///    `chrome-extension://` pages and `about:` aliases of WebUI pages, in
///    Chromium's canonical form (ChromiumInternalURL: `chrome://extensions`
///    is `chrome://extensions/`); every tab also takes the `chrome://` pages
///    cmux shows itself (ChromiumPageRoute), `cmux://stashed`, the Stashed Tabs page
///    (`cmuxAppPageHosts`; the App opens it), and Mac Screen addresses
///    (`cmux://mac-screen`; an old `cmux-vnc://pair?…` pairing link, which the host refuses
///    with a word and never loads). Every other scheme (`javascript:`,
///    `data:`, `mailto:`, ...) is searched, so typed text can never run
///    script or open another app.
/// 3. `/abs/path`, `~`, and `~/path` are file URLs, spaces allowed.
/// 4. Remaining text with whitespace is a search, except an explicit
///    `http`, `https` or `file` URL whose spaces all come after its host:
///    it loads with them percent-encoded, as in Chrome.
/// 5. Scheme-less text: userinfo (`user@host`) is refused, loopback hosts
///    and non-unique hosts (private IPs, `devbox:8080`, `router/`,
///    `nas.local`) get `http`, other dotted hosts, IPv6 literals or hosts
///    with a port get `https`, and single words search.
public nonisolated struct BrowserURLResolver: Sendable {
    private let homeDirectory: URL
    public var allowsChromiumSchemes: Bool

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, allowsChromiumSchemes: Bool = false) {
        self.homeDirectory = homeDirectory
        self.allowsChromiumSchemes = allowsChromiumSchemes
    }

    /// Whether `text` holds an old Mac Screen pairing link (`cmux-vnc://pair?…`
    /// or `cmux-vnc:pair?…`, any case, anywhere in the text). The link carries a
    /// room secret, so no input surface loads, searches or sends such text to an
    /// agent: the address bar, the New Tab field and `newTab.submit` refuse it with
    /// Mac Screen's word. The New Tab page's `newTabIntent.ts` keeps the same rule;
    /// `webviews/test/fixtures/new-tab-intents.json` holds both to it.
    public static func containsPairingLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        var rest = lower[...]
        while let scheme = rest.range(of: "cmux-vnc:") {
            let after = rest[scheme.upperBound...]
            if after.hasPrefix("pair") || after.hasPrefix("//pair") { return true }
            rest = after
        }
        return false
    }

    /// A URL to load, or nil when the text should be searched.
    public func url(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let text = removingWrapBreaks(trimmed) else { return nil }

        if let fileURL = fileURL(for: text) {
            return fileURL
        }
        guard !text.contains(where: \.isWhitespace) else { return encodingSpaces(text) }

        if let scheme = explicitScheme(of: text) {
            return explicitURL(text, scheme: scheme)
        }
        return schemeLessURL(text)
    }

    // MARK: Spaces

    /// An `http`, `https` or `file` URL with spaces only after its host
    /// (`https://x.com/search?q=a b`, `file:///My Notes.html`): the spaces
    /// percent-encoded, as Chrome loads them. Nil for everything else with
    /// a space, which is searched.
    private func encodingSpaces(_ text: String) -> URL? {
        guard let scheme = explicitScheme(of: text), ["http", "https", "file"].contains(scheme),
              let authorityStart = text.range(of: "://")?.upperBound,
              let authorityEnd = text[authorityStart...].firstIndex(where: { "/?#".contains($0) }),
              let firstSpace = text.firstIndex(where: \.isWhitespace), authorityEnd < firstSpace,
              text.allSatisfy({ !$0.isWhitespace || $0 == " " }) else {
            return nil
        }
        return explicitURL(text.replacingOccurrences(of: " ", with: "%20"), scheme: scheme)
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
            if rest.first.map({ "/?#".contains($0) }) ?? true {
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
            if text.lowercased() == "about:blank" { return URL(string: "about:blank") }
            return chromiumPage(text, scheme: scheme)
        case "chrome", "chrome-extension":
            return chromiumPage(text, scheme: scheme)
        case "cmux-vnc":
            return macScreenAddress(text, scheme: scheme)
        case "cmux":
            return macScreenAddress(text, scheme: scheme) ?? cmuxAppPage(text)
        default:
            return nil
        }
    }

    /// A Mac Screen address the host handles itself, never searched: a Mac
    /// Screen tab record (`cmux://mac-screen`), or an old pairing link
    /// (`cmux-vnc://pair?…`, which carries a room secret that must not reach a
    /// search engine or its suggestions; the host refuses it, pairing links
    /// being gone). No engine loads either.
    private func macScreenAddress(_ text: String, scheme: String) -> URL? {
        guard let url = URL(string: text) else { return nil }
        if scheme == "cmux-vnc" { return Self.containsPairingLink(text) ? url : nil }
        return url.host?.lowercased() == "mac-screen" ? url : nil
    }

    /// cmux's own pages that are no browser page, which the App opens instead of loading
    /// (ChromiumPageRouter). Every other `cmux:` link (`cmux://tab/…`) is searched, never run.
    package static let cmuxAppPageHosts: Set<String> = ["stashed"]

    /// `cmux://stashed` in canonical form, with any path, query or fragment dropped.
    private func cmuxAppPage(_ text: String) -> URL? {
        guard let host = URL(string: text)?.host()?.lowercased(), Self.cmuxAppPageHosts.contains(host) else { return nil }
        return URL(string: "cmux://\(host)")
    }

    /// A Chromium internal page in canonical form. A WebKit tab takes only
    /// the pages cmux shows itself (`chrome://history`, `chrome://bookmarks`,
    /// `chrome://settings`: ChromiumPageRoute); the host routes them.
    private func chromiumPage(_ text: String, scheme: String) -> URL? {
        guard let page = ChromiumInternalURL(text, scheme: scheme)?.url else { return nil }
        if allowsChromiumSchemes { return page }
        return ChromiumPageRoute(page)?.isCmuxOwned == true ? page : nil
    }

    // MARK: Scheme-less

    private func schemeLessURL(_ text: String) -> URL? {
        let authorityEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let authority = text[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        let (host, hasPort) = Self.splitHostAndPort(authority)
        guard !host.isEmpty else { return nil }

        let hasPath = text[authorityEnd...].hasPrefix("/")
        let scheme: String
        if Self.isLoopback(host) {
            scheme = "http"
        } else if Self.isNonUniqueHost(host) {
            // Chromium never upgrades IP literals in private ranges or
            // non-unique (intranet) names to https: a router, NAS or dev
            // server has no certificate. A single label needs a port or a
            // path ("devbox:8080", "router/"); alone it is a search
            // (`AutocompleteInput::Parse`).
            guard host.contains(where: { $0 == "." || $0 == ":" }) || hasPort || hasPath else { return nil }
            scheme = "http"
        } else if hasPort || Self.isDottedHost(host) || host.contains(":") {
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
    package static func splitHostAndPort(_ authority: Substring) -> (host: String, hasPort: Bool) {
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
    package static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// Names and addresses that are not globally unique, so they never get
    /// a public certificate: private, shared (CGNAT, tailnet) and
    /// link-local IPv4, unique-local and link-local IPv6, single-label
    /// hosts, and the reserved or intranet suffixes (RFC 6761, RFC 6762,
    /// `home.arpa`, `internal`). Chromium's `net::IsHostnameNonUnique`.
    package static func isNonUniqueHost(_ host: String) -> Bool {
        if host.contains(":") {
            let lower = host.lowercased()
            return lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
                || lower.hasPrefix("fea") || lower.hasPrefix("feb")
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4, octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.count == 1 { return !host.allSatisfy(\.isNumber) }
        let suffixes = ["local", "lan", "internal", "intranet", "corp", "home", "localdomain", "test", "example", "invalid", "home.arpa"]
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
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
