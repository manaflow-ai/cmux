public import CMUXMobileCore
public import Foundation

/// The current local Mac identity and settings that an offline policy must match exactly.
public struct CmxIrohHostPolicyExpectation: Equatable, Sendable {
    /// The authenticated account identifier, used only to derive an opaque cache scope.
    public let accountID: String

    /// The account device UUID owned by this Mac installation.
    public let deviceID: String

    /// The current app-instance UUID, which changes when the account or build tag changes.
    public let appInstanceID: String

    /// The build tag registered with the trust broker.
    public let tag: String

    /// The EndpointID derived from the current local Iroh secret key.
    public let endpointID: CmxIrohPeerIdentity

    /// The current local identity generation.
    public let identityGeneration: Int

    /// Whether offline same-account pairing is currently enabled.
    public let pairingEnabled: Bool

    /// The complete host capability set expected by this build.
    public let capabilities: [String]

    /// Creates a validated local expectation for an offline policy lookup.
    ///
    /// The raw account identifier remains transient. The cache persists only a
    /// SHA-256 scope derived from the account and app-instance identifiers.
    ///
    /// - Parameters:
    ///   - accountID: The current authenticated account identifier.
    ///   - deviceID: The account device's lowercase UUID.
    ///   - appInstanceID: The installation's lowercase app-instance UUID.
    ///   - tag: The safe build tag used for broker registration.
    ///   - endpointID: The current local Iroh EndpointID.
    ///   - identityGeneration: The positive local identity generation.
    ///   - pairingEnabled: Whether offline same-account pairing is enabled.
    ///   - capabilities: The complete bounded host capability set.
    /// - Throws: ``CmxIrohHostPolicyCacheError/invalidExpectation`` for malformed input.
    public init(
        accountID: String,
        deviceID: String,
        appInstanceID: String,
        tag: String,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String]
    ) throws {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              Self.isCanonicalUUID(deviceID),
              Self.isCanonicalUUID(appInstanceID),
              Self.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(Self.isSafeToken) else {
            throw CmxIrohHostPolicyCacheError.invalidExpectation
        }
        self.accountID = accountID
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.tag = tag
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
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
