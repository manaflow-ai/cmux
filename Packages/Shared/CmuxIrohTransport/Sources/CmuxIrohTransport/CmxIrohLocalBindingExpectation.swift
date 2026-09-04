public import CMUXMobileCore
import Foundation

/// The exact local endpoint tuple an authenticated discovery response must contain.
public struct CmxIrohLocalBindingExpectation: Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String

    /// The exact bundle-derived app namespace expected in discovery.
    public let clientNamespace: String
    public let tag: String
    public let platform: CmxIrohPlatform
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]

    public init(
        deviceID: String,
        appInstanceID: String,
        clientNamespace: String = "legacy",
        tag: String,
        platform: CmxIrohPlatform,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String]
    ) throws {
        guard Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              cmxIrohIsSafeToken(clientNamespace, maximumUTF8ByteCount: 255),
              cmxIrohIsSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ cmxIrohIsSafeToken($0) }) else {
            throw CmxIrohLocalBindingExpectationError.invalidExpectation
        }
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.clientNamespace = clientNamespace
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
            && binding.clientNamespace == clientNamespace
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

}
