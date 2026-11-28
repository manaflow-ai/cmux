public import CMUXMobileCore
import Foundation

/// Exact endpoint tuple signed into one side of a pair grant.
public struct CmxIrohGrantPeer: Decodable, Equatable, Sendable {
    public let bindingID: String
    public let deviceID: String
    public let tag: String
    public let platform: CmxIrohPlatform
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case deviceID = "deviceId"
        case tag
        case platform
        case endpointID = "endpointId"
        case identityGeneration
    }

    public init(binding: CmxIrohBrokerBinding) {
        bindingID = binding.bindingID
        deviceID = binding.deviceID
        tag = binding.tag
        platform = binding.platform
        endpointID = binding.endpointID
        identityGeneration = binding.identityGeneration
    }

    public init(
        bindingID: String,
        deviceID: String,
        tag: String,
        platform: CmxIrohPlatform,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.platform = platform
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindingID = try container.decode(String.self, forKey: .bindingID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        tag = try container.decode(String.self, forKey: .tag)
        platform = try container.decode(CmxIrohPlatform.self, forKey: .platform)
        endpointID = try CmxIrohPeerIdentity(
            endpointID: container.decode(String.self, forKey: .endpointID)
        )
        identityGeneration = try container.decode(Int.self, forKey: .identityGeneration)
    }
}

/// Verified authorization claims for one iOS-to-Mac app session.
public struct CmxIrohPairGrantClaims: Decodable, Equatable, Sendable {
    public let grantID: String
    public let issuedAt: Int64
    public let notBefore: Int64
    public let expiresAt: Int64
    public let alpn: String
    public let scope: String
    public let initiator: CmxIrohGrantPeer
    public let acceptor: CmxIrohGrantPeer

    private enum CodingKeys: String, CodingKey {
        case grantID = "jti"
        case issuedAt = "iat"
        case notBefore = "nbf"
        case expiresAt = "exp"
        case alpn
        case scope
        case initiator
        case acceptor
    }
}

/// Exact endpoint tuple expected in a cached endpoint attestation.
public struct CmxIrohEndpointExpectation: Equatable, Sendable {
    public let bindingID: String
    public let deviceID: String
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let platform: CmxIrohPlatform

    public init(binding: CmxIrohBrokerBinding) {
        bindingID = binding.bindingID
        deviceID = binding.deviceID
        endpointID = binding.endpointID
        identityGeneration = binding.identityGeneration
        platform = binding.platform
    }

    public init(
        bindingID: String,
        deviceID: String,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        platform: CmxIrohPlatform
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.platform = platform
    }
}

/// Verified one-day same-account proof for an endpoint binding.
public struct CmxIrohEndpointAttestationClaims: Decodable, Equatable, Sendable {
    public let version: Int
    public let attestationID: String
    public let accountSubject: String
    public let bindingID: String
    public let deviceID: String
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let platform: CmxIrohPlatform
    public let issuedAt: Int64
    public let notBefore: Int64
    public let expiresAt: Int64
    public let alpn: String
    public let scope: String

    private enum CodingKeys: String, CodingKey {
        case version
        case attestationID = "jti"
        case accountSubject = "sub"
        case bindingID = "bindingId"
        case deviceID = "deviceId"
        case endpointID = "endpointId"
        case identityGeneration
        case platform
        case issuedAt = "iat"
        case notBefore = "nbf"
        case expiresAt = "exp"
        case alpn
        case scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        attestationID = try container.decode(String.self, forKey: .attestationID)
        accountSubject = try container.decode(String.self, forKey: .accountSubject)
        bindingID = try container.decode(String.self, forKey: .bindingID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        endpointID = try CmxIrohPeerIdentity(
            endpointID: container.decode(String.self, forKey: .endpointID)
        )
        identityGeneration = try container.decode(Int.self, forKey: .identityGeneration)
        platform = try container.decode(CmxIrohPlatform.self, forKey: .platform)
        issuedAt = try container.decode(Int64.self, forKey: .issuedAt)
        notBefore = try container.decode(Int64.self, forKey: .notBefore)
        expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
        alpn = try container.decode(String.self, forKey: .alpn)
        scope = try container.decode(String.self, forKey: .scope)
    }
}

/// Both verified attestations from an offline same-account pairing attempt.
public struct CmxIrohVerifiedOfflinePair: Equatable, Sendable {
    public let initiator: CmxIrohEndpointAttestationClaims
    public let acceptor: CmxIrohEndpointAttestationClaims
}
