public import Foundation

/// Turns whatever a user types in the address bar into a loadable `URL`.
///
/// The phone address bar accepts three kinds of input, and this resolver maps
/// each to a concrete request, mirroring how a normal mobile browser omnibox
/// behaves:
///
/// - A full URL with a scheme (`https://example.com`) loads verbatim.
/// - A bare host or path that looks like a domain (`example.com`,
///   `localhost:3000`) is treated as an `https://` URL.
/// - Anything else (free text, multiple words) becomes a web search.
///
/// It is a pure value type with no I/O so it can be unit-tested in isolation,
/// which is where the address-bar correctness actually lives.
public struct BrowserURLResolver {
    /// The default search-engine query template. `%@` is replaced with the
    /// percent-encoded query.
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q=%@"

    /// The resolver is a unit of pure static functions; it is never
    /// instantiated.
    private init() {}

    /// Resolve raw address-bar text into a URL to load.
    ///
    /// - Parameters:
    ///   - input: The raw text the user submitted.
    ///   - searchTemplate: The search-URL template used when `input` is not a
    ///     URL. `%@` is replaced with the percent-encoded query. Defaults to
    ///     ``defaultSearchTemplate``.
    /// - Returns: A URL to load, or `nil` when `input` is empty after trimming.
    public static func resolve(
        _ input: String,
        searchTemplate: String = defaultSearchTemplate
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemed = schemedURL(from: trimmed) {
            return schemed
        }
        if looksLikeHost(trimmed) {
            // Local dev servers (localhost, loopback, private LAN) listen on
            // plain HTTP, and opening a local dev server is a central cmux
            // workflow. Forcing HTTPS would break them, so default those to
            // `http://` and everything else to `https://`. This matches the
            // desktop browser resolver's localhost/loopback special-casing.
            let scheme = isLocalHost(trimmed) ? "http" : "https"
            // A bare (unbracketed) IPv6 literal must be bracketed for the URL to
            // parse: `::1` -> `http://[::1]`.
            let authority = needsIPv6Brackets(trimmed) ? "[\(trimmed)]" : trimmed
            if let host = URL(string: "\(scheme)://\(authority)") {
                return host
            }
        }
        return searchURL(for: trimmed, template: searchTemplate)
    }

    /// Whether `input` is an unbracketed IPv6 literal (two or more colons, not
    /// already bracketed and without a path), so it must be wrapped in `[...]`
    /// to form a valid URL authority.
    private static func needsIPv6Brackets(_ input: String) -> Bool {
        guard !input.hasPrefix("["), !input.contains("/") else { return false }
        return input.filter { $0 == ":" }.count >= 2
    }

    /// Characters allowed unescaped when encoding a query-string *value*.
    ///
    /// `.urlQueryAllowed` is too permissive for a value substituted into
    /// `?q=...`: it leaves the parameter separators `&`, `=`, `+`, `?`, and `#`
    /// unescaped, so a search like `AT&T earnings` or `C++` would be split or
    /// reinterpreted by the endpoint. Subtracting those separators preserves the
    /// typed query verbatim.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

    /// Build a search URL for free-text input.
    ///
    /// - Parameters:
    ///   - query: The user's free-text query.
    ///   - template: The search-URL template; `%@` is replaced with the
    ///     percent-encoded query (encoded as a query-string value, so query
    ///     separators in the input are escaped).
    /// - Returns: The search URL, or `nil` if the template is malformed.
    public static func searchURL(for query: String, template: String = defaultSearchTemplate) -> URL? {
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: queryValueAllowed
        ) ?? query
        return URL(string: template.replacingOccurrences(of: "%@", with: encoded))
    }

    /// A URL with an explicit, http(s)-like scheme, or `nil` if `input` has no
    /// usable scheme. Schemes other than `http`/`https` are rejected so a typed
    /// `file:` or `javascript:` cannot be loaded from the address bar.
    private static func schemedURL(from input: String) -> URL? {
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        // A scheme with no host (`https://`) is not loadable; fall through to
        // the host/search heuristics by reporting no schemed URL.
        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    /// Whether `input` (which has no scheme) looks like a host the user wants to
    /// visit rather than a search query. A token is host-like when it has no
    /// spaces and contains a dot (`a.com`) or is a known local host
    /// (`localhost`, optionally with a port or path).
    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let host = bareHost(of: input)
        if host == "localhost" { return true }
        // An IPv6 literal (the bare-host extraction keeps the colons) is a host,
        // e.g. `::1` or a bracketed `[::1]:3000`.
        if host.filter({ $0 == ":" }).count >= 2 { return true }
        // A dotted token with a non-empty label on each side of the last dot
        // (so a trailing-dot or leading-dot string is not treated as a host).
        guard let lastDot = host.lastIndex(of: ".") else { return false }
        let afterDot = host[host.index(after: lastDot)...]
        let beforeDot = host[..<lastDot]
        return !afterDot.isEmpty && !beforeDot.isEmpty
    }

    /// Whether `input` targets a local dev host that should default to `http://`
    /// rather than `https://`: `localhost`, the IPv4 loopback `127.x.x.x`, the
    /// IPv6 loopback `::1`, or a private-LAN address (`10.x`, `192.168.x`,
    /// `172.16-31.x`). Opening a local dev server is a central cmux workflow and
    /// those servers listen on plain HTTP.
    private static func isLocalHost(_ input: String) -> Bool {
        let host = bareHost(of: input).lowercased()
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        let values = octets.compactMap { Int($0) }
        guard values.count == 4 else { return false }
        if values[0] == 127 { return true }                       // 127.0.0.0/8 loopback
        if values[0] == 10 { return true }                        // 10.0.0.0/8
        if values[0] == 192 && values[1] == 168 { return true }   // 192.168.0.0/16
        if values[0] == 172 && (16...31).contains(values[1]) { return true } // 172.16.0.0/12
        return false
    }

    /// The bare host of `input` (no scheme, no port, no path).
    ///
    /// Strips the path (first `/`), then the port. A bracketed IPv6 literal
    /// (`[::1]:3000`) keeps the address between the brackets; an unbracketed
    /// token containing multiple colons is treated as a bare IPv6 literal
    /// (`::1`) so the loopback comparison can match. A single-colon token is a
    /// `host:port` pair and keeps only the host.
    private static func bareHost(of input: String) -> String {
        let hostAndPort = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if hostAndPort.hasPrefix("[") {
            // Bracketed IPv6: take everything inside the brackets.
            if let close = hostAndPort.firstIndex(of: "]") {
                return String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<close])
            }
            return hostAndPort
        }
        let colonCount = hostAndPort.filter { $0 == ":" }.count
        if colonCount >= 2 {
            // Unbracketed multi-colon token: a bare IPv6 literal, no port.
            return hostAndPort
        }
        // host or host:port.
        return hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostAndPort
    }
}
