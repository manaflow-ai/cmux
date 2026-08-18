public import CMUXMobileCore

/// Structural failures at the device-only offline-grant boundary.
public enum PeerOfflineGrantCacheError: Error, Equatable, Sendable {
    case invalidExpectation
    case invalidPolicy
    case policyMismatch
    case invalidGrantEnvelope
}

/// The exact local endpoint tuple an authenticated discovery must contain.
public struct PeerLocalBindingExpectation: Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String
    /// The exact bundle-derived app namespace expected in discovery.
    public let clientNamespace: String
    public let tag: String
    public let platform: PeerPlatform
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let pairingEnabled: Bool
    public let capabilities: [String]

    public init(
        deviceID: String,
        appInstanceID: String,
        clientNamespace: String = "legacy",
        tag: String,
        platform: PeerPlatform,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String]
    ) throws {
        guard PeerBrokerWire.isCanonicalUUID(deviceID),
              PeerBrokerWire.isCanonicalUUID(appInstanceID),
              PeerBrokerWire.isSafeClientNamespace(clientNamespace),
              PeerBrokerWire.isSafeToken(tag),
              (1 ... Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ PeerBrokerWire.isSafeToken($0) }) else {
            throw PeerOfflineGrantCacheError.invalidExpectation
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
    public func matches(_ binding: PeerBrokerBinding) -> Bool {
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
}

/// The current account, app, endpoint, and relay authority for offline lookup.
///
/// Every field participates in cache scoping: a record saved under a
/// different account, app instance, local endpoint identity/generation, or
/// managed relay fleet never matches.
public struct PeerOfflineGrantExpectation: Equatable, Sendable {
    public let accountID: String
    public let localBindingExpectation: PeerLocalBindingExpectation
    public let managedRelayURLs: Set<String>

    public init(
        accountID: String,
        localBindingExpectation: PeerLocalBindingExpectation,
        managedRelayURLs: Set<String>
    ) throws {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              localBindingExpectation.platform == .ios,
              (1 ... PeerBrokerWire.maximumRelayCount).contains(managedRelayURLs.count),
              managedRelayURLs.allSatisfy(PeerBrokerWire.isCanonicalRelayURL) else {
            throw PeerOfflineGrantCacheError.invalidExpectation
        }
        self.accountID = accountID
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
    }
}

/// One exact, reverified iOS-to-Mac authority recovered from device storage.
public struct PeerCachedGrantAuthority: Equatable, Sendable {
    public let localBinding: PeerBrokerBinding
    public let targetBinding: PeerBrokerBinding
    public let pairGrant: PeerPairGrantResponse
    public let grantVerificationKeys: PeerGrantVerificationKeySet
    public let lanRendezvous: PeerBrokerLANRendezvous
}

struct PeerStoredGrantTarget: Codable, Equatable, Sendable {
    let binding: PeerBrokerBinding
    let pairGrant: PeerPairGrantResponse
}

/// Persisted record. Field names and JSON shape are unchanged from the
/// previous transport's stored client-policy record, so records written by
/// the old engine remain readable across the swap.
struct PeerStoredGrantRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let scopeDigest: String
    let localBinding: PeerBrokerBinding
    let relayFleet: [String]
    let grantVerificationKeys: PeerGrantVerificationKeySet
    let lanRendezvous: PeerBrokerLANRendezvous
    let targets: [PeerStoredGrantTarget]
}
