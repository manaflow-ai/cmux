import Foundation

/// Describes how the browser should select a client certificate for a host.
public struct BrowserClientCertificateAutoSelectionRule: Equatable, Hashable, Sendable {
    /// The action to take when the host pattern matches.
    public enum Selection: Equatable, Hashable, Sendable {
        /// Select the certificate automatically only when it is the sole candidate.
        case onlyCandidate
        /// Select the candidate whose certificate serial number matches this value.
        case certificateSerialNumber(String)
    }

    /// The URL pattern that identifies the protected site.
    public let pattern: BrowserURLAllowlistPattern

    /// The selection action for a matching protection space.
    public let selection: Selection

    /// Parses a rule such as `example.com` or `example.com = 0123ABCD`.
    ///
    /// A host-only rule is useful when the site has exactly one usable
    /// identity. Adding a serial number selects that identity when several
    /// certificates are available.
    public init?(_ value: String) {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstPart = parts.first else { return nil }
        let patternValue = String(firstPart).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pattern = BrowserURLAllowlistPattern(patternValue) else { return nil }

        if parts.count == 1 {
            self.selection = .onlyCandidate
        } else {
            let serialNumber = Self.normalizedSerialNumber(
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !serialNumber.isEmpty else { return nil }
            self.selection = .certificateSerialNumber(serialNumber)
        }
        self.pattern = pattern
    }

    /// Returns whether this rule applies to a WebKit client-certificate challenge.
    public func matches(_ protectionSpace: URLProtectionSpace) -> Bool {
        guard let scheme = protectionSpace.protocol,
              !scheme.isEmpty,
              !protectionSpace.host.isEmpty else {
            return false
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = protectionSpace.host
        components.port = protectionSpace.port > 0 ? protectionSpace.port : nil
        guard let url = components.url else { return false }
        return pattern.matches(url)
    }

    /// Normalizes a certificate serial number for comparison with Keychain metadata.
    public static func normalizedSerialNumber(_ value: String) -> String {
        value
            .filter { !$0.isWhitespace && $0 != ":" }
            .uppercased()
    }
}

/// Resolves browser settings for automatic client-certificate selection.
public struct BrowserClientCertificateAutoSelectionPolicy: Sendable {
    /// The `UserDefaults` key used by the Browser settings catalog.
    public static let userDefaultsKey = "browserAutoSelectCertificateForUrls"

    /// The normalized rules in their configured order.
    public let rules: [BrowserClientCertificateAutoSelectionRule]

    /// Creates a policy from a `UserDefaults` suite.
    public init(defaults: UserDefaults) {
        self.init(rawValues: Self.stringValues(from: defaults.object(forKey: Self.userDefaultsKey)))
    }

    /// Creates a policy from line-oriented or JSON-array-compatible rule values.
    public init(rules: [String]) {
        self.init(rawValues: rules)
    }

    private init(rawValues: [String]) {
        var seen = Set<BrowserClientCertificateAutoSelectionRule>()
        rules = rawValues
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap(BrowserClientCertificateAutoSelectionRule.init)
            .filter { seen.insert($0).inserted }
    }

    /// Returns the first configured selection action that matches a challenge.
    public func selection(for protectionSpace: URLProtectionSpace) -> BrowserClientCertificateAutoSelectionRule.Selection? {
        rules.first { $0.matches(protectionSpace) }?.selection
    }

    private static func stringValues(from rawValue: Any?) -> [String] {
        if let values = rawValue as? [String] { return values }
        if let values = rawValue as? NSArray { return values.compactMap { $0 as? String } }
        if let value = rawValue as? String { return [value] }
        return []
    }
}
