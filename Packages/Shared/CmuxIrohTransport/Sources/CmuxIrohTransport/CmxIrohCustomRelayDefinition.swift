public import Foundation

/// A non-secret custom relay definition synchronized through the account broker.
public struct CmxIrohCustomRelayDefinition: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case provider
        case region
        case displayName
        case authMode
    }

    /// Stable account-scoped identifier used to find device-local credentials.
    public let id: String

    /// Canonical HTTPS relay origin, including an optional explicit port.
    public let url: String

    /// User-defined provider label used only for selection and diagnostics.
    public let provider: String

    /// User-defined region label used only for selection and diagnostics.
    public let region: String

    /// Optional human-readable relay name.
    public let displayName: String?

    /// Authentication required by the relay.
    public let authMode: CmxIrohCustomRelayAuthMode

    /// Creates a validated, non-secret relay definition.
    public init(
        id: String,
        url: String,
        provider: String,
        region: String,
        displayName: String? = nil,
        authMode: CmxIrohCustomRelayAuthMode
    ) throws {
        guard Self.isSafeIdentifier(id),
              Self.isCanonicalURL(url),
              Self.isSafeLabel(provider),
              Self.isSafeLabel(region),
              displayName.map(Self.isSafeDisplayName) ?? true else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        self.id = id
        self.url = url
        self.provider = provider
        self.region = region
        self.displayName = displayName
        self.authMode = authMode
    }

    /// Decodes and revalidates one broker-supplied definition.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(String.self, forKey: .id),
                url: container.decode(String.self, forKey: .url),
                provider: container.decode(String.self, forKey: .provider),
                region: container.decode(String.self, forKey: .region),
                displayName: container.decodeIfPresent(String.self, forKey: .displayName),
                authMode: container.decode(CmxIrohCustomRelayAuthMode.self, forKey: .authMode)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid custom relay")
            )
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 95].contains(byte)
        }
    }

    private static func isSafeDisplayName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf16.count <= 128
            && !value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        guard (1 ... 80).contains(value.utf8.count),
              value.utf8.first != 32,
              value.utf8.last != 32 else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [32, 45, 46, 95].contains(byte)
        }
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
}
