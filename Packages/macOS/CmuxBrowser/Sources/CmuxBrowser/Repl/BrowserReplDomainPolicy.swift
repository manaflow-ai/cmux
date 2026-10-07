public import CmuxSettings
public import Foundation

/// Host names as the domain policy and secret scopes compare them: lower
/// case, without a trailing dot, internationalized labels in their ASCII
/// (Punycode) form, IPv6 in brackets, and an IP address in its canonical
/// spelling (`2130706433`, `0x7f.1` and `127.1` are `127.0.0.1`; `[0:0::1]`
/// is `[::1]`), as a URL parser reads it, so addresses compare as
/// addresses.
///
/// A host longer than ``maximumBytes`` is no host name (one is at most 253
/// bytes in ASCII); it is compared as given in lower case, never encoded or
/// parsed as an address, so agent code cannot make the session's thread
/// run Punycode (quadratic in a label's length) or a site walk (quadratic
/// in the label count) on an unbounded string.
enum BrowserReplHostName {
    /// The longest host normalized, in UTF-8 bytes: the 253 ASCII bytes of
    /// the longest DNS name, in a Unicode spelling of up to four bytes a
    /// character.
    static let maximumBytes = 1024

    static func isOverlong(_ host: String) -> Bool {
        host.utf8.count > maximumBytes
    }

    static func normalize(_ raw: String) -> String {
        if isOverlong(raw) { return raw.lowercased() }
        var host = raw.trimmingCharacters(in: .whitespaces)
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if host.hasPrefix("[") {
            let lowered = host.lowercased()
            return ipv6Address(lowered).map { "[\(ipv6Text($0))]" } ?? lowered
        }
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let lowered = String(label).precomposedStringWithCanonicalMapping.lowercased()
            guard lowered.unicodeScalars.contains(where: { !$0.isASCII }) else { return lowered }
            guard let encoded = Punycode.encode(lowered) else { return lowered }
            return "xn--" + encoded
        }
        let name = labels.joined(separator: ".")
        if isIPAddress(name), let address = ipv4Address(name) { return ipv4Text(address) }
        return name
    }

    /// The IPv4 address `host` names as a URL parser (WHATWG) reads it:
    /// one to four dot-separated parts, each decimal, `0x` hex or octal
    /// with a leading zero, the last filling the bytes the others leave.
    /// `nil` when it is not one.
    static func ipv4Address(_ host: String) -> UInt32? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            var digits = Substring(part.lowercased())
            var radix: UInt64 = 10
            if digits.hasPrefix("0x") {
                radix = 16
                digits = digits.dropFirst(2)
            } else if digits.count > 1, digits.hasPrefix("0") {
                radix = 8
                digits = digits.dropFirst()
            }
            guard !digits.isEmpty || radix == 16, !part.isEmpty else { return nil }
            var value: UInt64 = 0
            for character in digits {
                guard let digit = character.hexDigitValue, character.isASCII, UInt64(digit) < radix else { return nil }
                value = value * radix + UInt64(digit)
                guard value <= UInt64(UInt32.max) else { return nil }
            }
            numbers.append(value)
        }
        guard numbers.dropLast().allSatisfy({ $0 <= 255 }) else { return nil }
        let last = numbers[numbers.count - 1]
        guard last < (UInt64(1) << (8 * UInt64(5 - numbers.count))) else { return nil }
        var address = last
        for (index, number) in numbers.dropLast().enumerated() {
            address += number << (8 * UInt64(3 - index))
        }
        return UInt32(address)
    }

    static func ipv4Text(_ address: UInt32) -> String {
        (0..<4).map { String((address >> (8 * (3 - UInt32($0)))) & 0xff) }.joined(separator: ".")
    }

    /// The 16 bytes of the IPv6 address `host` (bracketed or not) names, or nil.
    static func ipv6Address(_ host: String) -> [UInt8]? {
        var text = host
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        guard text.contains(":") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6Text(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        let text = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: text, as: UTF8.self)
    }

    /// Why a URL whose host is written `raw` cannot be judged by its
    /// address, or nil. Foundation keeps the spelling a URL was given and
    /// the system resolver reads some spellings differently from a URL
    /// parser (`0177.0.0.1` is 127.0.0.1 to WebKit and 177.0.0.1 to
    /// `getaddrinfo`), so while a policy is set an IPv4 address must be
    /// written as four decimal parts, and one written as IPv6
    /// (`[::ffff:127.0.0.1]`) is refused.
    static func addressSpellingRefusal(_ raw: String) -> String? {
        let host = raw.lowercased()
        if host.contains(":") {
            guard let bytes = ipv6Address(host) else { return nil }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let mapped = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
                return "an IPv4 address written as IPv6 is refused while a domain policy is set; write it as \(ipv4Text(mapped))"
            }
            return nil
        }
        guard isIPAddress(host) else { return nil }
        guard let address = ipv4Address(host) else { return "\(raw) is not a valid IP address" }
        let canonical = ipv4Text(address)
        guard host == canonical else {
            return "the address \(raw) is refused while a domain policy is set; write it as \(canonical)"
        }
        return nil
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

    /// Whether `host` (normalized) is a loopback host: `localhost`, `[::1]`,
    /// or an IPv4 address in 127.0.0.0/8 written as four decimal parts
    /// (`127.0.0.1`). A name that only starts with `127.` is any host its
    /// domain's owner points it at, and another spelling of an address
    /// (`0177.0.0.1`) is read differently by the system resolver.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" { return true }
        guard let address = ipv4Address(host), ipv4Text(address) == host else { return false }
        return address >> 24 == 127
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
/// `http*://example.com`, `https://example.com:8443`, `*`. A leading `=`
/// names the exact host only (`=https://example.com`, never its www host):
/// the form the sign-in sheet's credentials take (``exactHost``).
public struct BrowserReplDomainPattern: Sendable, Equatable {
    public let raw: String
    public let scheme: String?
    public let host: String
    public let port: String?
    /// Whether the pattern names its host alone: a two-label host does not
    /// cover its www host too (`=example.com`).
    public let exactHost: Bool

    /// The most UTF-8 bytes a pattern may have.
    public static let maximumBytes = 1_024
    /// The most bytes a pattern's host may have in its ASCII form, a DNS
    /// name's limit.
    public static let maximumHostBytes = 253
    /// The most characters one label of a pattern's host may have, a DNS
    /// label's limit (a longer internationalized label encodes longer still).
    public static let maximumLabelCharacters = 63
    /// The most characters a pattern's scheme may have.
    public static let maximumSchemeCharacters = 32

    /// Parses `raw`; unsafe patterns (several wildcards, a wildcard TLD, a
    /// wildcard over a public suffix such as `*.com` or `*.co.uk`, or an
    /// embedded wildcard) are refused. `title` prefixes the error.
    ///
    /// Agent code chooses patterns, and each one costs every navigation
    /// check and the content rules WebKit compiles, so a pattern past
    /// ``maximumBytes``, a host past ``maximumHostBytes`` or with a label
    /// past ``maximumLabelCharacters``, and a scheme past
    /// ``maximumSchemeCharacters`` or with more than one wildcard are
    /// refused too; each is checked before the work it bounds, so parsing
    /// takes time linear in the pattern.
    /// - Parameter publicSuffixes: The list that decides whether a
    ///   wildcard's base is a public suffix.
    public static func parse(
        _ raw: String,
        title: String,
        publicSuffixes: BrowserReplPublicSuffixList = .system
    ) throws -> BrowserReplDomainPattern {
        let tooLong = raw.utf8.count > maximumBytes
        let quoted = JSONSerialization.browserReplString(tooLong ? String(raw.prefix(64)) + "..." : raw) ?? "?"
        guard !tooLong else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "\(title): \(quoted): a domain pattern is at most \(maximumBytes) bytes; this one is \(raw.utf8.count)"
            )
        }
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let exactHost = text.hasPrefix("=")
        if exactHost { text.removeFirst() }
        guard !text.isEmpty else {
            throw BrowserReplDriverError(code: "invalid", message: "\(title): expected domain patterns as non-empty strings, got \(quoted)")
        }
        var scheme: String?
        if let range = text.range(of: "://") {
            let candidate = String(text[..<range.lowerBound])
            if let first = candidate.unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(first) || first == "*",
               candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+.*-".unicodeScalars.contains($0) }) {
                if candidate.count > maximumSchemeCharacters {
                    throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): a scheme is at most \(maximumSchemeCharacters) characters")
                }
                if candidate.filter({ $0 == "*" }).count > 1 {
                    throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): only one wildcard is allowed in the scheme")
                }
                scheme = candidate
                text = String(text[range.upperBound...])
            }
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var port: String?
        // An IPv6 host is in brackets, with its port after them (`[::1]:3000`).
        let portColon = text.hasPrefix("[")
            ? text.lastIndex(of: "]").flatMap { close in text.index(after: close) < text.endIndex && text[text.index(after: close)] == ":" ? text.index(after: close) : nil }
            : text.lastIndex(of: ":")
        if let colon = portColon {
            let tail = String(text[text.index(after: colon)...])
            if tail == "*" || (!tail.isEmpty && tail.allSatisfy(\.isNumber)) {
                port = tail == "*" ? nil : tail
                text = String(text[..<colon])
            }
        }
        var host = text
        if exactHost, host.contains("*") {
            throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): = names one exact host; it takes no wildcard")
        }
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
            // Before the labels are encoded, which takes time quadratic in a
            // label's length.
            if host.split(separator: ".").contains(where: { $0.unicodeScalars.count > maximumLabelCharacters }) {
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "\(title): \(quoted): a label of a domain is at most \(maximumLabelCharacters) characters"
                )
            }
            host = host.hasPrefix("*.") ? "*." + BrowserReplHostName.normalize(String(host.dropFirst(2))) : BrowserReplHostName.normalize(host)
            if host.isEmpty || host == "*." {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): \(quoted): expected a domain")
            }
            let named = host.hasPrefix("*.") ? host.dropFirst(2) : Substring(host)
            if named.utf8.count > maximumHostBytes {
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "\(title): \(quoted): a domain is at most \(maximumHostBytes) characters (\(named.utf8.count) as written for DNS)"
                )
            }
            if host.hasPrefix("*."), !publicSuffixes.isAvailable {
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "\(title): \(quoted): the system's Public Suffix List could not be read, so a wildcard cannot be told from one over a public suffix such as *.com; name each host instead"
                )
            }
            if host.hasPrefix("*."), publicSuffixes.isPublicSuffix(String(host.dropFirst(2))) {
                let base = String(host.dropFirst(2))
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "\(title): \(quoted): \(base) is a public suffix, so *.\(base) would cover every site under it; name a site, such as *.example.\(base)"
                )
            }
        }
        return BrowserReplDomainPattern(raw: raw, scheme: scheme, host: host, port: port, exactHost: exactHost)
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
        // A root domain also covers www, unless the pattern names its exact host.
        return coversWWW && host == "www." + self.host
    }

    /// Whether the pattern's host is a root domain that also covers its www
    /// host: two labels, and not written as an exact host.
    var coversWWW: Bool {
        !exactHost && !host.hasPrefix("*") && host.split(separator: ".").count == 2
    }

    /// Whether every URL `other` lets load is on this pattern's hosts (and
    /// its scheme and port, when it names them): a domain policy whose
    /// allowed patterns this covers keeps pages on them. `secure`: this
    /// pattern is a secret scope, which without a scheme matches https only
    /// (http only on a loopback host; ``matches(_:secure:)``), so it covers
    /// only patterns that load nothing else; otherwise a pattern without a
    /// scheme covers either.
    func covers(_ other: BrowserReplDomainPattern, secure: Bool = false) -> Bool {
        if let port, other.port != port { return false }
        if let scheme {
            guard let theirs = other.scheme, Self.glob(scheme, matches: theirs) else { return false }
        } else if secure, !other.loadsOnlySecurely {
            return false
        }
        if host == "*" { return true }
        if other.host == "*" { return false }
        if other.host.hasPrefix("*.") { return coversSubdomains(of: String(other.host.dropFirst(2))) }
        guard hostMatches(other.host) else { return false }
        // A root domain also lets its www host load.
        return !other.coversWWW || hostMatches("www." + other.host)
    }

    /// Whether every URL this pattern lets load is one a secret scope
    /// without a scheme matches: it names https (or wss), or only a
    /// loopback host.
    var loadsOnlySecurely: Bool {
        if host != "*", !host.hasPrefix("*."), BrowserReplHostName.isLoopback(host) { return true }
        return scheme == "https" || scheme == "wss"
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

    static func glob(_ pattern: String, matches text: String) -> Bool {
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

    /// Whether this policy may block a URL `previous` allowed: it blocks IP
    /// addresses where `previous` did not, prohibits a pattern `previous`
    /// did not, or allows a list that lacks a pattern `previous` allowed
    /// (or `previous` allowed every host). Patterns are compared as
    /// written, so a change that cannot be shown to only widen counts as
    /// narrowing. Locking narrows nothing.
    public func narrows(_ previous: BrowserReplDomainPolicy) -> Bool {
        if blockIPAddresses, !previous.blockIPAddresses { return true }
        let earlierProhibited = Set(previous.prohibited.map(\.raw))
        if prohibited.contains(where: { !earlierProhibited.contains($0.raw) }) { return true }
        guard let allowed else { return false }
        guard let earlierAllowed = previous.allowed else { return true }
        let now = Set(allowed.map(\.raw))
        return earlierAllowed.contains { !now.contains($0.raw) }
    }

    /// The most patterns `allowed` or `prohibited` may hold: each pattern is
    /// checked on every navigation and becomes up to eight content rules.
    public static let maximumPatternsPerList = 1_024

    /// Why `urlString` is blocked, or nil when it may load.
    ///
    /// A `blob:` URL is judged by the origin embedded in it (the page that
    /// made it); one of an opaque origin (`blob:null/...`) is blocked, since
    /// the URL alone cannot say whose it is. `about:` and `data:` URLs pass:
    /// their document takes or is written by the document that opens it,
    /// which ``navigationBlockReason(_:initiator:)`` and the popup and frame
    /// checks judge instead.
    public func blockReason(_ urlString: String) -> String? {
        guard isActive else { return nil }
        let lower = urlString.lowercased()
        if lower.hasPrefix("blob:") {
            guard let inner = Self.blobOrigin(urlString) else {
                return "\(urlString.redactingBrowserReplURLCredentials()) belongs to an opaque origin, which the domain policy cannot judge"
            }
            return blockReason(inner)
        }
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") { return nil }
        var target = urlString
        if target.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) == nil { target = "https://" + target }
        guard let url = URL(string: target) else { return "not a valid URL" }
        guard let host = BrowserReplHostName.host(of: url) else {
            return "its scheme \(url.scheme.map { $0 + ":" } ?? "") has no host"
        }
        if blockIPAddresses, BrowserReplHostName.isIPAddress(host) {
            return "IP addresses are blocked (session.blockIPAddresses)"
        }
        if let raw = url.host(percentEncoded: false), let refusal = BrowserReplHostName.addressSpellingRefusal(raw) {
            return refusal
        }
        if let allowed, !allowed.contains(where: { $0.matches(url, secure: false) }) {
            return "not in session.allowedDomains (\(allowed.map(\.raw).joined(separator: ", ")))"
        }
        if let hit = prohibited.first(where: { $0.matches(url, secure: false) }) {
            return "prohibited by \(hit.raw) (session.prohibitedDomains)"
        }
        return nil
    }

    /// The URL embedded in `blob:<origin>/<id>` when its origin is a web
    /// origin with a host, or nil (an opaque origin, `blob:null/...`).
    static func blobOrigin(_ urlString: String) -> String? {
        let inner = String(urlString.dropFirst("blob:".count))
        guard let url = URL(string: inner), url.scheme != nil, BrowserReplHostName.host(of: url) != nil else { return nil }
        return inner
    }

    /// Why a main-frame navigation to `url` may not load, or nil.
    ///
    /// `initiator` is the document that started the navigation (WebKit's
    /// record of the source frame), nil when no page did (the agent's or the
    /// person's own load). An `about:` document (`about:blank`) takes the
    /// initiator's origin, a `data:` document is the initiator's own writing,
    /// and a `blob:` of an opaque origin was made by it: those are judged by
    /// the initiator, so a frame the policy blocks cannot move a tab to a
    /// document of its own origin. Other URLs, `blob:` URLs of a web origin
    /// included, are judged by ``blockReason(_:)`` and, when a page started
    /// the navigation, by the initiator too: a frame the policy blocks chose
    /// the URL (and can carry its page's data in it), so it cannot move the
    /// tab even to an allowed page.
    public func navigationBlockReason(_ url: URL, initiator: BrowserReplFrameDocument?) -> String? {
        guard isActive else { return nil }
        let raw = url.absoluteString
        switch url.scheme?.lowercased() {
        case "about", "data":
            return initiator.flatMap { blockReason(document: $0) }
        case "blob" where Self.blobOrigin(raw) == nil:
            guard let initiator else { return blockReason(raw) }
            return blockReason(document: initiator)
        default:
            if let reason = blockReason(raw) { return reason }
            return initiator.flatMap(initiatorBlockReason)
        }
    }

    /// Why a navigation or window the page `initiator` started may not go
    /// anywhere, or nil: the policy blocks that document.
    private func initiatorBlockReason(_ initiator: BrowserReplFrameDocument) -> String? {
        guard let reason = blockReason(document: initiator) else { return nil }
        return "it was started by \(initiator.origin.flatMap { $0 == "null" ? nil : $0 } ?? initiator.place), which the domain policy blocks: \(reason)"
    }

    /// Why the session may not read, set or clear a cookie on `domain`, or
    /// nil. A cookie belongs to a host, not an origin, so a pattern's scheme
    /// and port do not narrow it. A cookie with a Domain attribute (leading
    /// dot, `.example.com`) is in reach when a host an allowed pattern names
    /// receives it (its domain, or a parent domain of it, as `example.com`
    /// for `www.example.com`); a host-only cookie (no leading dot) goes to
    /// its own host alone, so it is in reach only when an allowed pattern
    /// names that host. Either is out of reach when its domain is one a
    /// prohibited pattern names or an IP address under `blockIPAddresses`.
    public func cookieBlockReason(domain: String) -> String? {
        guard isActive else { return nil }
        var raw = domain.trimmingCharacters(in: .whitespaces)
        let hostOnly = !raw.hasPrefix(".")
        while raw.hasPrefix(".") { raw.removeFirst() }
        let host = BrowserReplHostName.normalize(raw)
        guard !host.isEmpty else { return "the cookie names no domain" }
        if blockIPAddresses, BrowserReplHostName.isIPAddress(host) {
            return "IP addresses are blocked (session.blockIPAddresses)"
        }
        if let allowed, !allowed.contains(where: { hostOnly ? $0.hostMatches(host) : $0.receivesCookies(on: host) }) {
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
        // A host-only cookie's reach is its host, which cookieBlockReason checked.
        guard trimmed.hasPrefix(".") else { return nil }
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
                for filter in Self.filters(pattern, allowing: true) { add(filter, "ignore-previous-rules") }
            }
            // A document of these takes or is written by the document that
            // loads it, which loaded under these rules; a blob of a web
            // origin is judged by that origin (the filters' `(blob:)?`).
            for scheme in ["data", "about"] { add("^\(scheme):", "ignore-previous-rules") }
            add("^blob:null/", "ignore-previous-rules")
        }
        // An IPv4 address written as IPv6 (`[::ffff:c000:201]`) is refused
        // natively while a policy is set (`addressSpellingRefusal`), so no
        // allow filter (a universal host's IPv6 form) lets one load and no
        // IPv4 pattern is passed by it. This also refuses the rare address
        // whose fifth group is `ffff` after four zero groups.
        add("^(blob:)?[a-z][a-z0-9+.-]*://([^/@]*@)?\\[[0:]*:ffff:[0-9a-f.:]*\\]", "block")
        for pattern in prohibited {
            for filter in Self.filters(pattern, allowing: false) { add(filter, "block") }
        }
        if blockIPAddresses {
            add("^(blob:)?[a-z][a-z0-9+.-]*://([^/@]*@)?[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.?[:/]", "block")
            add("^(blob:)?[a-z][a-z0-9+.-]*://([^/@]*@)?\\[", "block")
        }
        return rules
    }

    /// The content rules a session's tabs carry: this policy's, then the
    /// local-file rules of the session's directories `roots`
    /// (``BrowserReplFileSandbox/contentRules(roots:subresourcesInsideRoots:)``)
    /// last, so no rule of the policy can undo their block of `file:` loads
    /// outside the directories, or of every `file:` subresource while a
    /// protected file may lie inside them. The policy's allow filters
    /// match web URLs only (``filters(_:allowing:)``). An allow list blocks every load it does
    /// not name, files inside the directories included, so under one the
    /// directories get no exception.
    public func contentRules(fileRoots roots: [String], subresourcesInsideRoots: Bool) -> [[String: Any]] {
        let exceptions = allowed == nil ? roots : []
        return contentRules + BrowserReplFileSandbox.contentRules(roots: exceptions, subresourcesInsideRoots: subresourcesInsideRoots)
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if ".+?^${}()|[]\\*".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The schemes a policy's content-rule filters may match.
    private static let webSchemes = ["http", "https", "ws", "wss"]

    /// The content-rule URL filters of `pattern`. An allow filter
    /// (`allowing`) matches web URLs only: a wildcard scheme (`*://host`)
    /// names ``webSchemes``, never `file:` (WebKit loads `file://host/p` as
    /// the local file `/p`) or another scheme, and a pattern that names
    /// none of them allows nothing. A block filter matches every scheme
    /// the pattern names, which only refuses more.
    static func filters(_ pattern: BrowserReplDomainPattern, allowing: Bool) -> [String] {
        let hosts: [String]
        if pattern.host == "*" {
            // Every host: a name or IPv4 address, and a bracketed IPv6
            // address, whose colons the first excludes. Content-rule
            // expressions have no alternation, so each is its own filter.
            hosts = ["[^/@:]+", "\\[[^/@]+\\]"]
        } else if pattern.host.hasPrefix("*.") {
            hosts = ["([^/@:]*\\.)?" + escape(String(pattern.host.dropFirst(2))) + "\\.?"]
        } else if pattern.coversWWW {
            // A root domain also covers www (`hostMatches`).
            hosts = ["(www\\.)?" + escape(pattern.host) + "\\.?"]
        } else {
            hosts = [escape(pattern.host) + "\\.?"]
        }
        return hosts.flatMap { filters(pattern, host: $0, allowing: allowing) }
    }

    /// ``filters(_:allowing:)`` for one host expression `host`.
    private static func filters(_ pattern: BrowserReplDomainPattern, host: String, allowing: Bool) -> [String] {
        // `blob:` URLs carry their origin: `blob:https://host/<id>`.
        func head(_ scheme: String) -> String { "^(blob:)?" + scheme + "://([^/@]*@)?" + host }
        let schemes: [String]
        if let scheme = pattern.scheme, allowing {
            schemes = webSchemes.filter { BrowserReplDomainPattern.glob(scheme, matches: $0) }
        } else if let scheme = pattern.scheme {
            schemes = [scheme.map { $0 == "*" ? "[a-z0-9+.-]*" : escape(String($0)) }.joined()]
        } else {
            schemes = webSchemes
        }
        guard !schemes.isEmpty else { return [] }
        guard let port = pattern.port else { return schemes.map { head($0) + "(:[0-9]+)?/" } }
        // A URL without a port has its scheme's default one (`matches`), so
        // the portless form is admitted only under the schemes whose default
        // is this port and that the pattern's scheme names.
        let defaultSchemes = ["443": ["https", "wss"], "80": ["http", "ws"]][port] ?? []
        let portless = defaultSchemes.filter { scheme in
            pattern.scheme.map { BrowserReplDomainPattern.glob($0, matches: scheme) } ?? true
        }
        return schemes.map { head($0) + ":" + port + "/" } + portless.map { head($0) + "/" }
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
    /// window with no URL) when the policy allows `opener`, the document of
    /// the frame that opened it, whose origin it takes, and `blob:` URLs
    /// whose origin is such a page. Whatever the URL, a window opens only
    /// when the policy allows `opener`: a blocked frame chose the URL and
    /// can carry its page's data in it.
    public func popupBlockReason(_ url: URL?, allowlist: BrowserURLAllowlistPolicy, opener: BrowserReplFrameDocument? = nil) -> String? {
        guard let url else { return openerBlockReason(opener) }
        let raw = url.absoluteString
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard allowlist.allows(url) else { return "the browser's URL allowlist does not allow \(raw)" }
            if let reason = blockReason(raw) { return reason }
            return opener.flatMap(initiatorBlockReason)
        case "about":
            let rest = raw.dropFirst("about:".count).lowercased()
            guard rest == "blank" || rest.hasPrefix("blank#") || rest.hasPrefix("blank?") else {
                return "a page may open about:blank, not \(raw)"
            }
            return openerBlockReason(opener)
        case "blob":
            guard let origin = URL(string: String(raw.dropFirst("blob:".count))),
                  ["http", "https"].contains(origin.scheme?.lowercased() ?? "") else {
                return "\(raw) does not belong to a web page"
            }
            return popupBlockReason(origin, allowlist: allowlist, opener: opener)
        case let scheme:
            return "a page may open only http, https, about:blank and blob: windows from a tab a REPL session drives, not \(scheme.map { $0 + ":" } ?? raw)"
        }
    }

    /// An `about:blank` window (or one with no URL) takes its opener's
    /// origin, and the opener can write into it: it opens only when the
    /// policy allows the opener's document.
    private func openerBlockReason(_ opener: BrowserReplFrameDocument?) -> String? {
        guard let opener, let reason = blockReason(document: opener) else { return nil }
        return "an about:blank window takes the origin of the frame that opened it, \(opener.origin.flatMap { $0 == "null" ? nil : $0 } ?? opener.place), which the domain policy blocks: \(reason)"
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
    ///   - opener: The document of the frame that opened the window (WebKit's
    ///     record of the navigation's source frame); an `about:blank` window
    ///     takes its origin.
    public init(
        url: URL?,
        openerCreatedBySession: Bool,
        creatorPolicy: BrowserReplDomainPolicy,
        inputSession: (id: String, policy: BrowserReplDomainPolicy)? = nil,
        allowlist: BrowserURLAllowlistPolicy,
        opener: BrowserReplFrameDocument? = nil
    ) {
        if openerCreatedBySession {
            self = creatorPolicy.popupBlockReason(url, allowlist: allowlist, opener: opener).map(Self.refused) ?? .session
        } else if let inputSession {
            self = inputSession.policy.popupBlockReason(url, allowlist: allowlist, opener: opener).map(Self.refused)
                ?? .inputSession(inputSession.id)
        } else {
            self = .browser
        }
    }
}
