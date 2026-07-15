public import CMUXMobileCore
import Foundation

/// The exact local endpoint tuple an authenticated discovery response must contain.
public struct CmxIrohLocalBindingExpectation: Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String
    public let tag: String
    public let platform: CmxIrohPlatform
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]

    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        platform: CmxIrohPlatform,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String]
    ) throws {
        guard Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              Self.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.isSafeToken) else {
            throw CmxIrohLocalBindingExpectationError.invalidExpectation
        }
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.tag = tag
        self.platform = platform
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
    }

    /// Returns whether `binding` is the single broker row this process registered.
    public func matches(_ binding: CmxIrohBrokerBinding) -> Bool {
        binding.deviceID == deviceID
            && binding.appInstanceID == appInstanceID
            && binding.tag == tag
            && binding.platform == platform
            && binding.endpointID == endpointID
            && binding.identityGeneration == identityGeneration
            && binding.pairingEnabled == pairingEnabled
            && binding.capabilities.count == capabilities.count
            && Set(binding.capabilities) == Set(capabilities)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
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
