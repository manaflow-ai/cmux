import Foundation

/// One parsed filter of ``BrowserURLFilter`` (Chrome's URL filter format).
nonisolated struct BrowserURLFilterRule: Sendable, Hashable {
    /// Lowercased scheme, nil for any.
    var scheme: String?
    /// Lowercased host without a trailing dot, empty for any host.
    var host: String
    /// The host matches its subdomains too (no leading dot, not an IP address).
    var matchesSubdomains: Bool
    var port: Int?
    /// Path prefix, empty for any path.
    var path: String
    /// Query parameters the URL must carry (`name=value`, or `name` for any value).
    var query: [String]

    /// How specific a filter is, to choose between a block and an allow match.
    struct Specificity: Comparable, Hashable, Sendable {
        var host: Int
        var path: Int
        var query: Int

        static func < (a: Specificity, b: Specificity) -> Bool {
            (a.host, a.path, a.query) < (b.host, b.path, b.query)
        }
    }

    var specificity: Specificity { Specificity(host: host.count, path: path.count, query: query.count) }

    init?(pattern raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "*" {
            self.init(scheme: nil, host: "", matchesSubdomains: true, port: nil, path: "", query: [])
            return
        }
        var scheme: String?
        if let range = text.range(of: "://") {
            scheme = text[..<range.lowerBound].lowercased()
            text = String(text[range.upperBound...])
            if scheme == "*" { scheme = nil }
        }
        var query: [String] = []
        if let mark = text.firstIndex(of: "?") {
            query = text[text.index(after: mark)...].split(separator: "&").map(String.init).filter { !$0.isEmpty }
            text = String(text[..<mark])
        }
        var path = ""
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            text = String(text[..<slash])
        }
        if path == "/" || path == "/*" { path = "" }
        if path.hasSuffix("*") { path.removeLast() }
        var host = text.lowercased()
        var port: Int?
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"), let number = Int(host[host.index(after: colon)...]) {
            port = number
            host = String(host[..<colon])
        } else if host.hasSuffix(":*") {
            host.removeLast(2)
        }
        var subdomains = true
        if host.hasPrefix(".") {
            subdomains = false
            host.removeFirst()
        }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "*" { host = "" }
        if Self.isIPAddress(host) { subdomains = false }
        guard !host.contains("*") else { return nil }
        // "file://*" style filters name a scheme without a host.
        guard !host.isEmpty || scheme != nil || !path.isEmpty || raw.contains("*") else { return nil }
        self.init(scheme: scheme, host: host, matchesSubdomains: subdomains, port: port, path: path, query: query)
    }

    init(scheme: String?, host: String, matchesSubdomains: Bool, port: Int?, path: String, query: [String]) {
        self.scheme = scheme
        self.host = host
        self.matchesSubdomains = matchesSubdomains
        self.port = port
        self.path = path
        self.query = query
    }

    func matches(_ url: URL) -> Bool {
        let urlScheme = url.scheme?.lowercased() ?? ""
        if let scheme, scheme != urlScheme { return false }
        if !host.isEmpty {
            var urlHost = (url.host(percentEncoded: false) ?? "").lowercased()
            while urlHost.hasSuffix(".") { urlHost.removeLast() }
            if urlHost.hasPrefix("[") && urlHost.hasSuffix("]") { urlHost = String(urlHost.dropFirst().dropLast()) }
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            guard urlHost == bare || (matchesSubdomains && urlHost.hasSuffix("." + bare)) else { return false }
        }
        if let port, port != (url.port ?? Self.defaultPort(urlScheme)) { return false }
        if !path.isEmpty {
            let urlPath = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
            guard urlPath.hasPrefix(path) else { return false }
        }
        if !query.isEmpty {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
            for wanted in query {
                let parts = wanted.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                let value = parts.count > 1 ? parts[1] : nil
                guard items.contains(where: { $0.name == name && (value == nil || $0.value == value) }) else { return false }
            }
        }
        return true
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": 80
        case "https", "wss": 443
        case "ftp": 21
        default: nil
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
