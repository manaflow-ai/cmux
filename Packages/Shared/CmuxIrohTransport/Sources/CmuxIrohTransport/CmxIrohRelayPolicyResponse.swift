/// Signed managed policy and the account preference revision resolved with it.
public struct CmxIrohRelayPolicyResponse: Codable, Equatable, Sendable {
    /// Compact Ed25519-signed managed relay policy.
    public let policy: String

    /// Complete current account configuration.
    public let preference: CmxIrohAccountRelayConfiguration

    /// Monotonic account preference revision.
    public let preferenceRevision: Int64

    /// Creates a validated relay policy response.
    public init(
        policy: String,
        preference: CmxIrohAccountRelayConfiguration,
        preferenceRevision: Int64
    ) throws {
        guard (1 ... 64 * 1_024).contains(policy.utf8.count),
              policy.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              preferenceRevision >= 0 else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        self.policy = policy
        self.preference = preference
        self.preferenceRevision = preferenceRevision
    }

    /// Decodes and revalidates one broker response.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                policy: container.decode(String.self, forKey: .policy),
                preference: container.decode(CmxIrohAccountRelayConfiguration.self, forKey: .preference),
                preferenceRevision: container.decode(Int64.self, forKey: .preferenceRevision)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid relay policy response")
            )
        }
    }
}
