/// Current account relay preference returned by the broker.
public struct CmxIrohRelayPreferenceResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case preference
        case revision = "preferenceRevision"
    }

    /// Complete current account configuration.
    public let preference: CmxIrohAccountRelayConfiguration

    /// Monotonic preference revision.
    public let revision: Int64

    /// Creates a validated preference response.
    public init(preference: CmxIrohAccountRelayConfiguration, revision: Int64) throws {
        guard revision >= 0 else { throw CmxIrohRelayPolicyError.invalidClaims }
        self.preference = preference
        self.revision = revision
    }

    /// Decodes and revalidates one preference response.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                preference: container.decode(CmxIrohAccountRelayConfiguration.self, forKey: .preference),
                revision: container.decode(Int64.self, forKey: .revision)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid preference response")
            )
        }
    }
}
