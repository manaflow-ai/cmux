import Foundation

/// One user-controlled Iroh relay and its optional static authentication token.
public struct CmxIrohCustomRelay: Equatable, Sendable {
    /// Canonical HTTPS relay origin, including an optional explicit port.
    public let url: String

    /// Optional relay authentication token, which must be persisted in secure storage.
    public let authenticationToken: String?

    /// Creates a validated custom relay.
    ///
    /// - Parameters:
    ///   - url: Canonical HTTPS origin ending in `/`; an explicit port is allowed.
    ///   - authenticationToken: Optional provider-defined static token.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidClaims`` for unsafe input.
    public init(url: String, authenticationToken: String? = nil) throws {
        guard Self.isCanonicalURL(url),
              authenticationToken.map(Self.isSafeToken) ?? true else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        self.url = url
        self.authenticationToken = authenticationToken
    }

    private static func isCanonicalURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/" else {
            return false
        }
        return components.string == value
    }

    private static func isSafeToken(_ value: String) -> Bool {
        (1 ... 8 * 1_024).contains(value.utf8.count)
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
