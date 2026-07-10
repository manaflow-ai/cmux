public import Foundation

/// A broker-issued Mac host policy eligible for verified offline fallback.
public struct CmxIrohCachedHostPolicy: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case binding
        case pairingEnabled
        case capabilities
        case grantVerificationKeys
        case endpointAttestation
        case lanRendezvous
    }

    /// The exact registered broker binding recovered by this policy.
    public let binding: CmxIrohBrokerBindingMetadata

    /// The broker-approved offline pairing state.
    public let pairingEnabled: Bool

    /// The complete broker-approved host capability set.
    public let capabilities: [String]

    /// The broker signing keyset used to verify grants and this attestation.
    public let grantVerificationKeys: CmxIrohGrantVerificationKeySet

    /// The signed, short-lived proof for this exact endpoint binding.
    public let endpointAttestation: CmxIrohEndpointAttestationResponse

    /// Same-account material used to derive private rotating LAN aliases.
    public let lanRendezvous: CmxIrohLANRendezvous

    /// Creates a cache candidate from exact broker policy values.
    ///
    /// Cryptographic signature, binding, and time validation happens again in
    /// ``CmxIrohHostPolicyCache/save(_:for:now:)`` before persistence.
    ///
    /// - Parameters:
    ///   - binding: The exact broker binding metadata.
    ///   - pairingEnabled: The broker-approved offline pairing state.
    ///   - capabilities: The complete broker-approved capability set.
    ///   - grantVerificationKeys: The authenticated broker verification keyset.
    ///   - endpointAttestation: The broker-signed endpoint attestation response.
    /// - Throws: ``CmxIrohHostPolicyCacheError/invalidPolicy`` for malformed policy shape.
    public init(
        binding: CmxIrohBrokerBindingMetadata,
        pairingEnabled: Bool,
        capabilities: [String],
        grantVerificationKeys: CmxIrohGrantVerificationKeySet,
        endpointAttestation: CmxIrohEndpointAttestationResponse,
        lanRendezvous: CmxIrohLANRendezvous
    ) throws {
        guard binding.platform == .mac,
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.isSafeToken),
              endpointAttestation.attestationVersion == 1,
              endpointAttestation.grantVerificationKeys == grantVerificationKeys else {
            throw CmxIrohHostPolicyCacheError.invalidPolicy
        }
        self.binding = binding
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.grantVerificationKeys = grantVerificationKeys
        self.endpointAttestation = endpointAttestation
        self.lanRendezvous = lanRendezvous
    }

    /// Creates a cache candidate directly from one validated broker binding.
    ///
    /// - Parameters:
    ///   - binding: The binding returned by registration or authenticated discovery.
    ///   - grantVerificationKeys: The authenticated discovery keyset.
    ///   - endpointAttestation: The broker-signed endpoint attestation response.
    /// - Throws: ``CmxIrohHostPolicyCacheError/invalidPolicy`` for malformed policy shape.
    public init(
        binding: CmxIrohBrokerBinding,
        grantVerificationKeys: CmxIrohGrantVerificationKeySet,
        endpointAttestation: CmxIrohEndpointAttestationResponse,
        lanRendezvous: CmxIrohLANRendezvous
    ) throws {
        try self.init(
            binding: CmxIrohBrokerBindingMetadata(binding: binding),
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            grantVerificationKeys: grantVerificationKeys,
            endpointAttestation: endpointAttestation,
            lanRendezvous: lanRendezvous
        )
    }

    /// Decodes and revalidates a persisted policy's structural invariants.
    ///
    /// - Parameter decoder: The decoder containing one cached host policy.
    /// - Throws: ``CmxIrohHostPolicyCacheError/invalidPolicy`` or a decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            binding: container.decode(CmxIrohBrokerBindingMetadata.self, forKey: .binding),
            pairingEnabled: container.decode(Bool.self, forKey: .pairingEnabled),
            capabilities: container.decode([String].self, forKey: .capabilities),
            grantVerificationKeys: container.decode(
                CmxIrohGrantVerificationKeySet.self,
                forKey: .grantVerificationKeys
            ),
            endpointAttestation: container.decode(
                CmxIrohEndpointAttestationResponse.self,
                forKey: .endpointAttestation
            ),
            lanRendezvous: container.decode(
                CmxIrohLANRendezvous.self,
                forKey: .lanRendezvous
            )
        )
    }

    private static func isSafeToken(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }
}
