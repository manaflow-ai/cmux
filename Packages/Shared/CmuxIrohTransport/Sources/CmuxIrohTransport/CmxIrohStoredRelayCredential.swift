import Foundation

/// Versioned Keychain payload for one binding-scoped relay capability.
struct CmxIrohStoredRelayCredential: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let binding: CmxIrohBrokerBindingMetadata
    let response: CmxIrohRelayTokenResponse

    init(
        binding: CmxIrohBrokerBindingMetadata,
        response: CmxIrohRelayTokenResponse
    ) {
        version = Self.currentVersion
        self.binding = binding
        self.response = response
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        binding = try container.decode(CmxIrohBrokerBindingMetadata.self, forKey: .binding)
        switch storedVersion {
        case 1:
            response = CmxIrohRelayTokenResponse(
                token: try container.decode(String.self, forKey: .token),
                expiresAt: try container.decode(String.self, forKey: .expiresAt),
                refreshAfter: try container.decode(String.self, forKey: .refreshAfter),
                relayFleet: try container.decode([String].self, forKey: .relayFleet)
            )
        case Self.currentVersion:
            response = try container.decode(
                CmxIrohRelayTokenResponse.self,
                forKey: .response
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported relay credential version"
            )
        }
        version = Self.currentVersion
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(binding, forKey: .binding)
        try container.encode(response, forKey: .response)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case binding
        case response
        case token
        case expiresAt
        case refreshAfter
        case relayFleet
    }
}
