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
    /// An opaque account-scoped digest of the provider-local profile.
    public let profileID: String

    /// Creates a provider-qualified profile key.
    /// - Parameters:
    ///   - source: The provider that owns the identifier namespace.
    ///   - profileID: A 32-byte account-scoped digest encoded as canonical
    ///     lowercase hexadecimal. Human-readable network names must be hashed
    ///     before constructing this value so discovery cannot disclose them.
    /// - Throws: ``CmxIrohNetworkProfileKeyError/invalidProfileID`` when the
    ///   identifier cannot be represented safely on the wire.
    public init(source: CmxIrohPathHintSource, profileID: String) throws {
        guard profileID.utf8.count == 64,
              profileID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw CmxIrohNetworkProfileKeyError.invalidProfileID
        }
        self.source = source
        self.profileID = profileID
    }

    /// Decodes and validates a provider-qualified profile key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(CmxIrohPathHintSource.self, forKey: .source),
            profileID: container.decode(String.self, forKey: .profileID)
        )
    }
}
