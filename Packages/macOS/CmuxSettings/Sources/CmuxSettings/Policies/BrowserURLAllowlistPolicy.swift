import CmuxCore
import Foundation

/// A single host-based rule for the embedded-browser URL allowlist.
public struct BrowserURLAllowlistPattern: Equatable, Hashable, Sendable {
    /// The normalized rule text used for diagnostics and persistence.
    public let rawValue: String

    /// An optional scheme restriction (`http` or `https`).
    public let scheme: String?

    /// The normalized host without brackets or a trailing dot.
    public let host: String

    /// An optional explicit TCP port restriction.
    public let port: Int?

    /// Whether the host rule matches a subdomain suffix.
    public let matchesSubdomains: Bool

    /// Parses a host, wildcard host, or URL-shaped rule.
    ///
    /// Accepted forms are `example.com`, `*.example.com`,
    /// `https://git.example.com`, and `http://localhost:3000`. Paths,
    /// queries, fragments, credentials, and schemes other than HTTP(S) are
    /// rejected because the policy governs web origins rather than resources.
    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        var parsedScheme: String?
        if let schemeSeparator = candidate.range(of: "://") {
            let rawScheme = String(candidate[..<schemeSeparator.lowerBound]).lowercased()
            guard rawScheme == "http" || rawScheme == "https" else { return nil }
            parsedScheme = rawScheme
            candidate = String(candidate[schemeSeparator.upperBound...])
        }

        if candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        guard !candidate.contains("/") && !candidate.contains("?") && !candidate.contains("#") && !candidate.contains("@") else {
            return nil
        }
        guard !candidate.hasSuffix(":") else { return nil }

        let wildcard = candidate.hasPrefix("*.")
        if wildcard {
            candidate = String(candidate.dropFirst(2))
        }
        guard !candidate.isEmpty, !candidate.contains("*") else { return nil }
        candidate = candidate.lowercased()

        if !candidate.hasPrefix("["),
           candidate.filter({ $0 == ":" }).count == 1,
           let colon = candidate.lastIndex(of: ":"),
           !candidate[candidate.index(after: colon)...].allSatisfy(\.isNumber) {
            return nil
        }

        let hostAndPort = Self.splitHostAndPort(candidate)
        guard let normalizedHost = RemoteLoopbackProxyAlias.normalizeHost(hostAndPort.host) else {
            return nil
        }
        guard Self.isValidHost(normalizedHost) else { return nil }
        guard hostAndPort.port == nil || (1...65_535).contains(hostAndPort.port!) else {
            return nil
        }

        self.scheme = parsedScheme
        self.host = normalizedHost
        self.port = hostAndPort.port
        self.matchesSubdomains = wildcard

        var normalized = ""
        if let parsedScheme { normalized += "\(parsedScheme)://" }
        if wildcard { normalized += "*." }
        if normalizedHost.contains(":") {
            normalized += "[\(normalizedHost)]"
        } else {
            normalized += normalizedHost
        }
        if let port { normalized += ":\(port)" }
        self.rawValue = normalized
    }

    /// Returns whether this rule matches the URL's scheme, host, and port.
    public func matches(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let urlHost = url.host,
              let normalizedURLHost = RemoteLoopbackProxyAlias.normalizeHost(urlHost) else {
            return false
        }
        guard urlScheme == "http" || urlScheme == "https" else { return false }
        if let scheme, scheme != urlScheme { return false }
        if let port {
            let effectivePort = url.port ?? Self.defaultPort(for: urlScheme)
            guard effectivePort == port else { return false }
        }
        let candidateHosts = [
            normalizedURLHost,
            RemoteLoopbackProxyAlias.localhostFamilyHost(
                forAliasHost: normalizedURLHost,
                aliasHost: RemoteLoopbackProxyAlias.aliasHost
            )
        ].compactMap { $0 }
        return candidateHosts.contains { candidateHost in
            if matchesSubdomains {
                return candidateHost.hasSuffix(".\(host)")
            }
            return candidateHost == host
        }
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func splitHostAndPort(_ value: String) -> (host: String, port: Int?) {
        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]") else {
                return (value, nil)
            }
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            let remainder = String(value[value.index(after: closingBracket)...])
            guard remainder.isEmpty || remainder.first == ":" else {
                return (value, nil)
            }
            if remainder.first == ":" && Self.port(from: remainder) == nil {
                return (value, nil)
            }
            return (host, Self.port(from: remainder))
        }

        let colonCount = value.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        guard colonCount == 1, let colon = value.lastIndex(of: ":") else {
            // An unbracketed IPv6 literal has multiple colons and no portable
            // way to distinguish a port; URL-shaped rules must use brackets.
            return (value, nil)
        }
        let possiblePort = String(value[value.index(after: colon)...])
        guard let port = Int(possiblePort), !possiblePort.isEmpty else {
            return (value, nil)
        }
        return (String(value[..<colon]), port)
    }

    private static func port(from suffix: String) -> Int? {
        guard suffix.first == ":" else { return nil }
        return Int(suffix.dropFirst())
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else { return false }
        if host.contains(":") {
            return URL(string: "https://[\(host)]")?.host == host
        }
        return URL(string: "https://\(host)")?.host?.lowercased() == host
    }
}

/// Resolves the effective MDM or user URL allowlist for embedded browsing.
public struct BrowserURLAllowlistPolicy: Equatable, Sendable {
    /// The administrator-facing forced preference key in `com.cmuxterm.app`.
    public static let managedDefaultsKey = ManagedDevicePolicyKey.browserURLAllowlist.rawValue

    /// The regular user preference key used by Settings and `cmux.json`.
    public static let userDefaultsKey = "browserURLAllowlist"

    /// Loopback origins allowed by default for local development servers.
    ///
    /// These are suggested user-level entries, not an MDM policy. Saving a
    /// custom list in Settings or `cmux.json` makes the entries effective, and
    /// removing one removes that origin from the effective list.
    public static let defaultPatterns = [
        "localhost",
        "*.localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]

    /// The editable text shown for the default user allowlist.
    public static let defaultAllowlistText = defaultPatterns.joined(separator: "\n")

    /// The source that supplied the effective rules.
    public enum Source: Equatable, Sendable {
        /// No restriction is configured.
        case none
        /// The user/team setting supplied the rules.
        case user
        /// A forced configuration profile supplied the rules.
        case managed
    }

    /// Schemes that app-owned loads may use without an origin rule. Page-
    /// initiated navigations to these schemes still go through ``allows(_:)``
    /// and are denied while a managed list is active.
    public static let trustedInternalSchemes: Set<String> = [
        "about", "applewebdata", "blob", "cmux-browser-action", "cmux-diff-viewer",
        "data", "file", "javascript"
    ]

    /// Schemes for cmux-owned documents that WebKit may request while showing
    /// a blocked/error document. These remain available to page-policy checks.
    private static let alwaysAllowedDocumentSchemes: Set<String> = [
        "about", "applewebdata", "cmux-browser-action", "cmux-diff-viewer"
    ]

    /// The effective source.
    public let source: Source

    /// The valid, normalized rules. When ``source`` is ``Source/none`` because
    /// no user override exists, this contains the suggested loopback entries
    /// even though navigation remains unrestricted. A non-empty user value
    /// whose rules are all invalid remains active with no matching patterns,
    /// so it fails closed; invalid forced values are likewise managed and fail
    /// closed.
    public let patterns: [BrowserURLAllowlistPattern]

    /// Whether the administrator supplied a forced key, including an empty or
    /// malformed forced value.
    public var isManaged: Bool { source == .managed }

    /// Whether navigation is restricted. A missing or explicitly empty user
    /// value leaves the optional user restriction off. A non-empty user value,
    /// including one containing only invalid rules, is restrictive. A managed
    /// empty list remains restrictive.
    public var isActive: Bool { source != .none }

    /// Resolves the policy from the supplied preference suite.
    ///
    /// - Parameters:
    ///   - defaults: The app/channel preference suite.
    ///   - managedDevicePolicy: An optional injected resolver for tests or a
    ///     composition root that already owns one.
    public init(
        defaults: UserDefaults = .standard,
        managedDevicePolicy: ManagedDevicePolicy? = nil
    ) {
        let resolver = managedDevicePolicy ?? ManagedDevicePolicy(defaults: defaults)
        if let forced = resolver.forcedBrowserURLAllowlistObject(
            userDefaultsKey: Self.userDefaultsKey
        ) {
            self.source = .managed
            self.patterns = Self.patterns(from: Self.stringValues(from: forced))
            return
        }

        guard defaults.object(forKey: Self.userDefaultsKey) != nil else {
            self.source = .none
            self.patterns = Self.patterns(from: Self.defaultPatterns)
            return
        }

        let userValues = Self.stringValues(from: defaults.object(forKey: Self.userDefaultsKey))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let userPatterns = Self.patterns(from: userValues)
        // Empty text clears the optional restriction. A non-empty value whose
        // rules all fail validation stays active and therefore fails closed.
        self.source = userValues.isEmpty ? .none : .user
        self.patterns = userPatterns
    }

    /// Creates a policy from explicit rules, primarily for deterministic tests.
    public init(managedPatterns: [String]?, userPatterns: [String] = []) {
        if let managedPatterns {
            source = .managed
            patterns = Self.patterns(from: managedPatterns)
        } else {
            let normalizedValues = userPatterns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            source = normalizedValues.isEmpty ? .none : .user
            patterns = Self.patterns(from: normalizedValues)
        }
    }

    /// Whether a URL may be loaded in the embedded browser.
    public func allows(_ url: URL) -> Bool {
        guard isActive else { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        if Self.alwaysAllowedDocumentSchemes.contains(scheme) { return true }
        return patterns.contains { $0.matches(url) }
    }

    /// Whether an app-owned load may use a local or generated document URL.
    ///
    /// Callers must use this only for a navigation they initiated themselves;
    /// WebKit delegate callbacks use ``allows(_:)`` so page scripts cannot
    /// turn `file:`, `data:`, `blob:`, or `javascript:` into an origin-policy
    /// bypass. Local file URLs must be absolute, have no credentials or port,
    /// and be hostless (or use the `localhost` host); network-host and relative
    /// file URLs remain denied.
    public func allowsTrustedInternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return isLocalFileURL(url) }
        guard isActive else { return true }
        return Self.trustedInternalSchemes.contains(scheme) || allows(url)
    }

    private static func patterns(from values: [String]) -> [BrowserURLAllowlistPattern] {
        var seen = Set<BrowserURLAllowlistPattern>()
        return values.compactMap { BrowserURLAllowlistPattern($0) }.filter { seen.insert($0).inserted }
    }

    private func isLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        guard let host = url.host?.lowercased() else { return true }
        return host.isEmpty || host == "localhost"
    }

    private static func stringValues(from rawValue: Any?) -> [String] {
        if let values = rawValue as? [String] {
            return values.flatMap(Self.tokens(from:))
        }
        if let values = rawValue as? NSArray {
            return values.compactMap { $0 as? String }.flatMap(Self.tokens(from:))
        }
        if let value = rawValue as? String {
            return Self.tokens(from: value)
        }
        return []
    }

    private static func tokens(from rawValue: String) -> [String] {
        rawValue.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t"))
    }
}
