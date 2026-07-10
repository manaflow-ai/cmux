import Foundation

/// Versioned Keychain payload for one binding-scoped relay capability.
struct CmxIrohStoredRelayCredential: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let binding: CmxIrohBrokerBindingMetadata
    let token: String
    let expiresAt: String
    let refreshAfter: String
    let relayFleet: [String]

    init(
        binding: CmxIrohBrokerBindingMetadata,
        response: CmxIrohRelayTokenResponse
    ) {
        version = Self.currentVersion
        self.binding = binding
        token = response.token
        expiresAt = response.expiresAt
        refreshAfter = response.refreshAfter
        relayFleet = response.relayFleet
    }

    var response: CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: token,
            expiresAt: expiresAt,
            refreshAfter: refreshAfter,
            relayFleet: relayFleet
        )
    }
}
