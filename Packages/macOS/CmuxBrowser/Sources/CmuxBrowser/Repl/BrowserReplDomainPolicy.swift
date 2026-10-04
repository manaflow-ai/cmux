public import CmuxSettings
public import Foundation

/// Host names as the domain policy and secret scopes compare them: lower
/// case, without a trailing dot, internationalized labels in their ASCII
/// (Punycode) form, IPv6 in brackets.
enum BrowserReplHostName {
    static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespaces)
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if host.hasPrefix("[") { return host.lowercased() }
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let lowered = String(label).precomposedStringWithCanonicalMapping.lowercased()
            guard lowered.unicodeScalars.contains(where: { !$0.isASCII }) else { return lowered }
            guard let encoded = Punycode.encode(lowered) else { return lowered }
            return "xn--" + encoded
        }
        return labels.joined(separator: ".")
    }

    /// The normalized host of `url`, or nil when it has none.
    static func host(of url: URL) -> String? {
        guard let raw = url.host(percentEncoded: false), !raw.isEmpty else { return nil }
        return normalize(raw)
    }

    /// Whether `host` (normalized) is an IP address: bracketed IPv6, or a
    /// name whose last label is a number, which URL parsers read as IPv4
    /// (`127.1`, `0x7f.0.0.1`, `2130706433`).
    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        guard let last = host.split(separator: ".").last, !last.isEmpty else { return false }
        let label = last.lowercased()
        if label.allSatisfy(\.isNumber) { return true }
        if label.hasPrefix("0x") { return label.dropFirst(2).allSatisfy(\.isHexDigit) }
        return false
    }

    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

/// RFC 3492 Punycode, encoding only.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ d: Int) -> Character {
        Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22)))
    }

    private static func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}

/// A domain pattern in reference C's syntax: `example.com` (and
/// `www.example.com`), `*.example.com` (subdomains and the bare domain),
/// `http*://example.com`, `https://example.com:8443`, `*`.
public struct BrowserReplDomainPattern: Sendable, Equatable {
    public let raw: String
    public let scheme: String?
    public let host: String
    public let port: String?

    /// Parses `raw`; unsafe patterns (several wildcards, a wildcard TLD, a
    /// wildcard over a public suffix such as `*.com` or `*.co.uk`, or an
    /// embedded wildcard) are refused. `title` prefixes the error.
    /// - Parameter publicSuffixes: The list that decides whether a
    ///   wildcard's base is a public suffix.
    public static func parse(
        _ raw: String,
        title: String,
        publicSuffixes: BrowserReplPublicSuffixList = .system
    ) throws -> BrowserReplDomainPattern {
        let quoted = JSONSerialization.browserReplString(raw) ?? raw
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else {
            throw BrowserReplDriverError(code: "invalid", message: "\(title): expected domain patterns as non-empty strings, got \(quoted)")
        }
        var scheme: String?
        if let range = text.range(of: "://") {
            let candidate = String(text[..<range.lowerBound])
            if let first = candidate.unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(first) || first == "*",
               candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+.*-".unicodeScalars.contains($0) }) {
                scheme = candidate
                text = String(text[range.upperBound...])
            }
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var port: String?
        if !text.hasPrefix("["), let colon = text.lastIndex(of: ":") {
            let tail = String(text[text.index(after: colon)...])
            if tail == "*" || (!tail.isEmpty && tail.allSatisfy(\.isNumber)) {
                port = tail == "*" ? nil : tail
                text = String(text[..<colon])
            }
        }
        var host = text
        if host != "*" {
            if host.filter({ $0 == "*" }).count > 1 {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): only one wildcard is allowed")
            }
            if host.hasSuffix(".*") {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): wildcard top-level domains are not allowed")
            }
            if host.contains("*"), !host.hasPrefix("*.") {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): use *.example.com; other wildcards are not allowed")
            }
            if host.isEmpty || host.contains(where: { $0.isWhitespace || $0 == "/" }) {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): expected a domain")
            }
            host = host.hasPrefix("*.") ? "*." + BrowserReplHostName.normalize(String(host.dropFirst(2))) : BrowserReplHostName.normalize(host)
            if host.isEmpty || host == "*." {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): expected a domain")
            }
            if host.hasPrefix("*."), publicSuffixes.isPublicSuffix(String(host.dropFirst(2))) {
                let base = String(host.dropFirst(2))
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "\(title): \(quoted): \(base) is a public suffix, so *.\(base) would cover every site under it; name a site, such as *.example.\(base)"
                )
            }
        }
        return BrowserReplDomainPattern(raw: raw, scheme: scheme, host: host, port: port)
    }

    /// Whether `url` matches. `secure`: a pattern without a scheme matches
    /// https only (and http on a loopback host), as secret scopes require;
    /// otherwise http and https.
    public func matches(_ url: URL, secure: Bool) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), let host = BrowserReplHostName.host(of: url) else { return false }
        if let scheme {
            guard Self.glob(scheme, matches: urlScheme) else { return false }
        } else if secure {
            guard urlScheme == "https" || (urlScheme == "http" && BrowserReplHostName.isLoopback(host)) else { return false }
        } else {
            guard urlScheme == "http" || urlScheme == "https" else { return false }
        }
        if let port {
            let actual = url.port.map(String.init) ?? (urlScheme == "https" || urlScheme == "wss" ? "443" : (urlScheme == "http" || urlScheme == "ws" ? "80" : ""))
            guard actual == port else { return false }
        }
        return hostMatches(host)
    }

    /// Whether a normalized origin (`scheme://host[:port]`) matches, with
    /// `secure` semantics.
    public func matches(origin: String, secure: Bool) -> Bool {
        guard let url = URL(string: origin + "/") else { return false }
        return matches(url, secure: secure)
    }

    func hostMatches(_ host: String) -> Bool {
        if self.host == "*" { return true }
        if self.host.hasPrefix("*.") {
            let base = String(self.host.dropFirst(2))
            return host == base || host.hasSuffix("." + base)
        }
        if host == self.host { return true }
        // A root domain also covers www.
        return self.host.split(separator: ".").count == 2 && host == "www." + self.host
    }

    /// Whether a host this pattern names receives cookies set on `domain`
    /// (normalized): the domain itself or one of its subdomains.
    func receivesCookies(on domain: String) -> Bool {
        if hostMatches(domain) { return true }
        if host == "*" { return true }
        let named = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return named.hasSuffix("." + domain)
    }

    /// Whether every host under `domain` (it and all its subdomains) matches.
    func coversSubdomains(of domain: String) -> Bool {
        if host == "*" { return true }
        guard host.hasPrefix("*.") else { return false }
        let base = String(host.dropFirst(2))
        return domain == base || domain.hasSuffix("." + base)
    }

    /// Whether a host this pattern names is `domain` or one of its subdomains.
    func namesSubdomain(of domain: String) -> Bool {
        if host == "*" { return true }
        let named = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return named == domain || named.hasSuffix("." + domain) || domain.hasSuffix("." + named)
    }

    private static func glob(_ pattern: String, matches text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return text.range(of: "^" + escaped + "$", options: .regularExpression) != nil
    }

    /// The pattern as JSON for the driver.
    public var json: [String: Any] {
        var out: [String: Any] = ["raw": raw, "host": host]
        if let scheme { out["scheme"] = scheme }
        if let port { out["port"] = port }
        return out
    }

    /// Rebuilds a pattern sent as `json`, normalizing it again.
    public static func from(json: [String: Any]) -> BrowserReplDomainPattern? {
        guard let raw = json["raw"] as? String else { return nil }
        return try? parse(raw, title: "pattern")
    }
}

/// The session's domain policy (docs/browser-repl/reference-c-parity.md):
/// navigations, new tabs, fetch (every redirect hop) and subresources may
/// reach only allowed domains and never prohibited ones. It lives in the
/// native session, not in the REPL's JavaScript, and a locked policy cannot
/// change for the rest of the session.
public struct BrowserReplDomainPolicy: Sendable, Equatable {
    public var allowed: [BrowserReplDomainPattern]?
    public var prohibited: [BrowserReplDomainPattern] = []
    public var blockIPAddresses = false
    public var locked = false

    public init() {}

    public var isActive: Bool { allowed != nil || !prohibited.isEmpty || blockIPAddresses }

    /// Why `urlString` is blocked, or nil when it may load.
    public func blockReason(_ urlString: String) -> String? {
        guard isActive else { return nil }
        let lower = urlString.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("blob:") { return nil }
        var target = urlString
        if target.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) == nil { target = "https://" + target }
        guard let url = URL(string: target) else { return "not a valid URL" }
        guard let host = BrowserReplHostName.host(of: url) else {
            return "its scheme \(url.scheme.map { $0 + ":" } ?? "") has no host"
        }
        if blockIPAddresses, BrowserReplHostName.isIPAddress(host) {
            return "IP addresses are blocked (session.blockIPAddresses)"
        }
        if let allowed, !allowed.contains(where: { $0.matches(url, secure: false) }) {
            return "not in session.allowedDomains (\(allowed.map(\.raw).joined(separator: ", ")))"
        }
        if let hit = prohibited.first(where: { $0.matches(url, secure: false) }) {
            return "prohibited by \(hit.raw) (session.prohibitedDomains)"
        }
        return nil
    }

    /// Why a main-frame navigation to `url` may not load, or nil.
    public func navigationBlockReason(_ url: URL, initiator: BrowserReplFrameDocument?) -> String? {
        blockReason(url.absoluteString)
    }

    /// Why the session may not read, set or clear a cookie on `domain`, or
    /// nil. A cookie belongs to a host, not an origin, so a pattern's scheme
    /// and port do not narrow it. A cookie is in reach when a host an allowed
    /// pattern names receives it (its domain, or a parent domain of it, as
    /// `example.com` for `www.example.com`), and out of reach when its domain
    /// is one a prohibited pattern names or an IP address under
    /// `blockIPAddresses`.
    public func cookieBlockReason(domain: String) -> String? {
        guard isActive else { return nil }
        var raw = domain.trimmingCharacters(in: .whitespaces)
        while raw.hasPrefix(".") { raw.removeFirst() }
        let host = BrowserReplHostName.normalize(raw)
        guard !host.isEmpty else { return "the cookie names no domain" }
        if blockIPAddresses, BrowserReplHostName.isIPAddress(host) {
            return "IP addresses are blocked (session.blockIPAddresses)"
        }
        if let allowed, !allowed.contains(where: { $0.receivesCookies(on: host) }) {
            return "not in session.allowedDomains (\(allowed.map(\.raw).joined(separator: ", ")))"
        }
        if let hit = prohibited.first(where: { $0.hostMatches(host) }) {
            return "prohibited by \(hit.raw) (session.prohibitedDomains)"
        }
        return nil
    }

    /// Why the session may not set a cookie on `domain`, or nil. Stricter
    /// than reading: a cookie set with a Domain attribute (`.example.com`)
    /// reaches every subdomain, so it is refused unless an allowed pattern
    /// covers all of them (`*` or `*.example.com`), and refused when a
    /// prohibited host is among them. A host-only cookie (no leading dot)
    /// reaches only its host.
    public func cookieSetBlockReason(domain: String) -> String? {
        if let reason = cookieBlockReason(domain: domain) { return reason }
        guard isActive else { return nil }
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(".") else {
            let host = BrowserReplHostName.normalize(trimmed)
            if let allowed, !allowed.contains(where: { $0.hostMatches(host) }) {
                return "not in session.allowedDomains (\(allowed.map(\.raw).joined(separator: ", ")))"
            }
            return nil
        }
        let host = BrowserReplHostName.normalize(String(trimmed.drop(while: { $0 == "." })))
        if let allowed, !allowed.contains(where: { $0.coversSubdomains(of: host) }) {
            return "a cookie on \(host) reaches its other subdomains, which session.allowedDomains (\(allowed.map(\.raw).joined(separator: ", "))) does not all allow; set it on the allowed host itself"
        }
        if let hit = prohibited.first(where: { $0.namesSubdomain(of: host) }) {
            return "a cookie on \(host) reaches \(hit.raw) (session.prohibitedDomains)"
        }
        return nil
    }

    /// `{ allowed, prohibited, blockIPs, locked }` with the raw patterns.
    public var json: [String: Any] {
        [
            "allowed": allowed.map { patterns -> Any in patterns.map(\.raw) } ?? NSNull(),
            "prohibited": prohibited.map(\.raw),
            "blockIPs": blockIPAddresses,
            "locked": locked,
        ]
    }

    // MARK: Content rules

    private static let subresources = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket", "other"]

    /// WebKit content-blocker rules for the policy: iframes and every
    /// subresource of a blocked domain are blocked. Main-frame documents are
    /// left to the navigation checks, which report the block. Content-blocker
    /// expressions have no alternation, so each pattern becomes its own rule;
    /// hosts may end in a dot, which names the same host.
    public var contentRules: [[String: Any]] {
        guard isActive else { return [] }
        var rules: [[String: Any]] = []
        func add(_ filter: String, _ action: String) {
            rules.append(["trigger": ["url-filter": filter, "resource-type": Self.subresources], "action": ["type": action]])
            rules.append(["trigger": ["url-filter": filter, "resource-type": ["document"], "load-context": ["child-frame"]], "action": ["type": action]])
        }
        if let allowed {
            add(".*", "block")
            for pattern in allowed {
                for filter in Self.filters(pattern) { add(filter, "ignore-previous-rules") }
            }
            for scheme in ["data", "blob", "about"] { add("^\(scheme):", "ignore-previous-rules") }
        }
        for pattern in prohibited {
            for filter in Self.filters(pattern) { add(filter, "block") }
        }
        if blockIPAddresses {
            add("^[a-z][a-z0-9+.-]*://([^/@]*@)?[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.?[:/]", "block")
            add("^[a-z][a-z0-9+.-]*://([^/@]*@)?\\[", "block")
        }
        return rules
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if ".+?^${}()|[]\\*".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    static func filters(_ pattern: BrowserReplDomainPattern) -> [String] {
        let schemes = pattern.scheme.map { scheme in
            [scheme.map { $0 == "*" ? "[a-z0-9+.-]*" : escape(String($0)) }.joined()]
        } ?? ["https?", "wss?"]
        return schemes.flatMap { scheme -> [String] in
            let host: String
            if pattern.host == "*" {
                host = "[^/@:]+"
            } else if pattern.host.hasPrefix("*.") {
                host = "([^/@:]*\\.)?" + escape(String(pattern.host.dropFirst(2))) + "\\.?"
            } else {
                host = escape(pattern.host) + "\\.?"
            }
            let head = "^" + scheme + "://([^/@]*@)?" + host
            guard let port = pattern.port else { return [head + "(:[0-9]+)?/"] }
            var out = [head + ":" + port + "/"]
            let schemeText = pattern.scheme
            if (port == "443" && (schemeText == nil || schemeText!.hasPrefix("https") || schemeText == "*"))
                || (port == "80" && (schemeText == nil || schemeText!.hasPrefix("http") || schemeText == "*")) {
                out.append(head + "/")
            }
            return out
        }
    }
}

// MARK: - Page-opened windows

extension BrowserReplDomainPolicy {
    /// Why a window a page opens from a tab a REPL session drives may not
    /// open, or nil. Called on the creating session's policy (an inactive
    /// one for a user's tab).
    ///
    /// cmux opens such a window as a new tab through its own navigation,
    /// which trusts local files and cmux's internal schemes, but the page
    /// controls the URL. So only web pages open: http and https URLs the
    /// browser's URL allowlist and this policy allow, `about:blank` (also a
    /// window with no URL), and `blob:` URLs whose origin is such a page.
    public func popupBlockReason(_ url: URL?, allowlist: BrowserURLAllowlistPolicy, opener: BrowserReplFrameDocument? = nil) -> String? {
        guard let url else { return nil }
        let raw = url.absoluteString
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard allowlist.allows(url) else { return "the browser's URL allowlist does not allow \(raw)" }
            return blockReason(raw)
        case "about":
            let rest = raw.dropFirst("about:".count).lowercased()
            return rest == "blank" || rest.hasPrefix("blank#") || rest.hasPrefix("blank?")
                ? nil
                : "a page may open about:blank, not \(raw)"
        case "blob":
            guard let origin = URL(string: String(raw.dropFirst("blob:".count))),
                  ["http", "https"].contains(origin.scheme?.lowercased() ?? "") else {
                return "\(raw) does not belong to a web page"
            }
            return popupBlockReason(origin, allowlist: allowlist)
        case let scheme:
            return "a page may open only http, https, about:blank and blob: windows from a tab a REPL session drives, not \(scheme.map { $0 + ":" } ?? raw)"
        }
    }
}

/// Where a window a page opens, from a tab REPL sessions drive, goes.
public enum BrowserReplPopupRoute: Equatable, Sendable {
    /// To the REPL sessions driving the tab, as a new background tab.
    case session
    /// To the session whose input the user's tab was handling, as a new
    /// background tab that stays the user's (never closed with the session).
    case inputSession(String)
    /// The browser's own popup path, as if no session drove the tab.
    case browser
    /// Nowhere: the window does not open.
    case refused(String)

    /// Routes a window the page in a driven tab opens. Only a tab a session
    /// created hands its windows to the sessions: a user's tab that a
    /// session drives keeps them, so no session adopts (and at its end
    /// closes) a window the user's page opened. The page controls the URL,
    /// and a session's popup opens through cmux's own navigation, which
    /// trusts local files and internal schemes, so it goes to the sessions
    /// only if it passes as an untrusted navigation under the browser's URL
    /// allowlist and the creating session's domain policy; otherwise it
    /// does not open.
    ///
    /// A user's tab that opens a window while it handles a session's own
    /// input (an agent's click) is the exception: the browser's path would
    /// put a key popup window over the user's work, out of the agent's
    /// reach, so the window opens as a background tab for that session, under
    /// the same URL checks with that session's policy, and stays the user's.
    ///
    /// - Parameters:
    ///   - openerCreatedBySession: Whether an attached session created the
    ///     opener tab (`BrowserReplTabOwnership.isSessionOwned`).
    ///   - creatorPolicy: That session's domain policy.
    ///   - inputSession: The session whose input the opener tab is handling,
    ///     with its domain policy, if any.
    public init(
        url: URL?,
        openerCreatedBySession: Bool,
        creatorPolicy: BrowserReplDomainPolicy,
        inputSession: (id: String, policy: BrowserReplDomainPolicy)? = nil,
        allowlist: BrowserURLAllowlistPolicy,
        opener: BrowserReplFrameDocument? = nil
    ) {
        if openerCreatedBySession {
            self = creatorPolicy.popupBlockReason(url, allowlist: allowlist).map(Self.refused) ?? .session
        } else if let inputSession {
            self = inputSession.policy.popupBlockReason(url, allowlist: allowlist).map(Self.refused)
                ?? .inputSession(inputSession.id)
        } else {
            self = .browser
        }
    }
}
