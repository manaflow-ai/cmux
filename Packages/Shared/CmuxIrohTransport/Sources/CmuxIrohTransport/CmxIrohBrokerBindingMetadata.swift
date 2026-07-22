public import CMUXMobileCore
import Foundation

/// The exact broker binding tuple needed to recover one registered endpoint.
public struct CmxIrohBrokerBindingMetadata: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case bindingID
        case deviceID
        case appInstanceID
        case tag
        case platform
        case endpointID
        case identityGeneration
    }

    /// The broker-owned binding UUID.
    public let bindingID: String

    /// The account device UUID associated with the installation.
    public let deviceID: String

    /// The installation's broker-facing app-instance UUID.
    public let appInstanceID: String

    /// The build tag registered with the broker.
    public let tag: String

    /// The endpoint's platform role.
    public let platform: CmxIrohPlatform

    /// The cryptographic endpoint identity bound by the broker.
    public let endpointID: CmxIrohPeerIdentity

    /// The monotonically increasing endpoint identity generation.
    public let identityGeneration: Int

    /// Creates validated broker binding metadata.
    ///
    /// - Parameters:
    ///   - bindingID: The broker-owned lowercase binding UUID.
    ///   - deviceID: The account device's lowercase UUID.
    ///   - appInstanceID: The installation's lowercase app-instance UUID.
    ///   - tag: The safe build tag sent during registration.
    ///   - platform: The endpoint's platform role.
    ///   - endpointID: The registered Iroh endpoint identity.
    ///   - identityGeneration: The positive endpoint identity generation.
    /// - Throws: ``CmxIrohBrokerCredentialRepositoryError/invalidBinding`` for malformed input.
    public init(
        bindingID: String,
        deviceID: String,
        appInstanceID: String,
        tag: String,
        platform: CmxIrohPlatform,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int
    ) throws {
        guard Self.isCanonicalUUID(bindingID),
              Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              Self.isSafeTag(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration) else {
            throw CmxIrohBrokerCredentialRepositoryError.invalidBinding
        }
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.tag = tag
        self.platform = platform
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
    }

    /// Copies the exact recovery tuple from a validated broker response.
    ///
    /// - Parameter binding: The binding returned by registration or discovery.
    public init(binding: CmxIrohBrokerBinding) {
        bindingID = binding.bindingID
        deviceID = binding.deviceID
        appInstanceID = binding.appInstanceID
        tag = binding.tag
        platform = binding.platform
        endpointID = binding.endpointID
        identityGeneration = binding.identityGeneration
    }

    /// Decodes and revalidates persisted broker binding metadata.
    ///
    /// - Parameter decoder: The decoder containing one binding tuple.
    /// - Throws: ``CmxIrohBrokerCredentialRepositoryError/invalidBinding`` for malformed input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bindingID: container.decode(String.self, forKey: .bindingID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            appInstanceID: container.decode(String.self, forKey: .appInstanceID),
            tag: container.decode(String.self, forKey: .tag),
            platform: container.decode(CmxIrohPlatform.self, forKey: .platform),
            endpointID: container.decode(CmxIrohPeerIdentity.self, forKey: .endpointID),
            identityGeneration: container.decode(Int.self, forKey: .identityGeneration)
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSafeTag(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }
}
