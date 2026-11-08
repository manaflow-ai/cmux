public import CMUXMobileCore
public import Foundation

/// Structural failures at the device-only iOS offline-policy boundary.
public enum CmxIrohClientOfflinePolicyCacheError: Error, Equatable, Sendable {
    case invalidExpectation
    case invalidPolicy
    case policyMismatch
    case invalidGrantEnvelope
}

/// The current account, app, endpoint, and relay authority for offline lookup.
public struct CmxIrohClientOfflinePolicyExpectation: Equatable, Sendable {
    public let accountID: String
    public let localBindingExpectation: CmxIrohLocalBindingExpectation
    public let managedRelayURLs: Set<String>

    public init(
        accountID: String,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>
    ) throws {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              localBindingExpectation.platform == .ios,
              (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
                  managedRelayURLs.count
              ),
              managedRelayURLs.allSatisfy(Self.isCanonicalRelayURL) else {
            throw CmxIrohClientOfflinePolicyCacheError.invalidExpectation
        }
        self.accountID = accountID
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
    }

    private static func isCanonicalRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/" else {
            return false
        }
        return components.string == value
    }
}

/// One exact, reverified iOS-to-Mac authority recovered from device-only storage.
public struct CmxIrohCachedClientPolicy: Equatable, Sendable {
    public let localBinding: CmxIrohBrokerBinding
    public let targetBinding: CmxIrohBrokerBinding
    public let pairGrant: CmxIrohPairGrantResponse
    public let grantVerificationKeys: CmxIrohGrantVerificationKeySet
    public let lanRendezvous: CmxIrohLANRendezvous
}

/// Reverified route material used only to bootstrap an already-known account.
public struct CmxIrohClientOfflineBootstrap: Equatable, Sendable {
    public let localBinding: CmxIrohBrokerBinding
    public let targetBindings: [CmxIrohBrokerBinding]
    public let lanRendezvous: CmxIrohLANRendezvous
}

/// Immutable cache scope installed into a dial-time registry context provider.
public struct CmxIrohClientOfflinePolicyContext: Sendable {
    public let cache: CmxIrohClientOfflinePolicyCache
    public let expectation: CmxIrohClientOfflinePolicyExpectation
    public let localBinding: CmxIrohBrokerBinding

    public init(
        cache: CmxIrohClientOfflinePolicyCache,
        expectation: CmxIrohClientOfflinePolicyExpectation,
        localBinding: CmxIrohBrokerBinding
    ) throws {
        guard expectation.localBindingExpectation.matches(localBinding) else {
            throw CmxIrohClientOfflinePolicyCacheError.policyMismatch
        }
        self.cache = cache
        self.expectation = expectation
        self.localBinding = localBinding
    }
}

struct CmxIrohStoredClientPolicyTarget: Codable, Equatable, Sendable {
    let binding: CmxIrohBrokerBinding
    let pairGrant: CmxIrohPairGrantResponse
}

struct CmxIrohStoredClientPolicyRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let scopeDigest: String
    let localBinding: CmxIrohBrokerBinding
    let relayFleet: [String]
    let grantVerificationKeys: CmxIrohGrantVerificationKeySet
    let lanRendezvous: CmxIrohLANRendezvous
    let targets: [CmxIrohStoredClientPolicyTarget]
}
