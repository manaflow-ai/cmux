/// A provider-qualified private-network profile.
///
/// The provider is part of the key so equal profile names from Tailscale, a
/// LAN observer, and a custom VPN can never authorize one another's hints.
public struct CmxIrohNetworkProfileKey: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case source
        case profileID = "profile_id"
    }

    /// The provider that owns this profile namespace.
    public let source: CmxIrohPathHintSource
    /// The provider-local profile identifier.
    public let profileID: String

    /// Creates a provider-qualified profile key.
    /// - Parameters:
    ///   - source: The provider that owns the identifier namespace.
    ///   - profileID: A stable provider-local profile identifier.
    /// - Throws: ``CmxIrohNetworkProfileKeyError/invalidProfileID`` when the
    ///   identifier cannot be represented safely on the wire.
    public init(source: CmxIrohPathHintSource, profileID: String) throws {
        guard Self.isSafeIdentifier(profileID) else {
            throw CmxIrohNetworkProfileKeyError.invalidProfileID
        }
        self.source = source
        self.profileID = profileID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(CmxIrohPathHintSource.self, forKey: .source),
            profileID: container.decode(String.self, forKey: .profileID)
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 58
                || byte == 95
        }
    }
}

/// Validation failures for provider-qualified network profiles.
public enum CmxIrohNetworkProfileKeyError: Error, Equatable, Sendable {
    /// The provider-local identifier was empty, too long, or contained unsafe
    /// wire characters.
    case invalidProfileID
}
