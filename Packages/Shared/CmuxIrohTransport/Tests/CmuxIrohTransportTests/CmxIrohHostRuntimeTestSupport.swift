import CMUXMobileCore
import CryptoKit
import Foundation
@testable import CmuxIrohTransport

struct HostRuntimeFixture {
    let identity: CmxIrohIdentityMaterial
    let endpointID: CmxIrohPeerIdentity
    let binding: CmxIrohBrokerBinding
    let discovery: CmxIrohDiscoveryResponse
    let managedRelays: Set<String>
    let configuration: CmxIrohHostRuntimeConfiguration

    init(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        publicHintLifetime: TimeInterval? = nil
    ) throws {
        let secret = Data(repeating: 0x31, count: 32)
        identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: secret),
            generation: 4
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        endpointID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        managedRelays = Set(Self.relayURLs)
        binding = try Self.binding(
            endpointID: endpointID.endpointID,
            publicHintObservedAt: publicHintLifetime == nil ? nil : now,
            publicHintExpiresAt: publicHintLifetime.map(now.addingTimeInterval)
        )
        discovery = try Self.discovery(
            binding: binding,
            relays: Self.relayURLs
        )
        configuration = CmxIrohHostRuntimeConfiguration(
            accountID: "account-a",
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            managedRelayURLs: managedRelays
        )
    }

    func configuration(
        cachedHostPolicy: CmxIrohCachedHostPolicy? = nil,
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        endpointRelayProfile: CmxIrohEndpointRelayProfile? = nil
    ) -> CmxIrohHostRuntimeConfiguration {
        CmxIrohHostRuntimeConfiguration(
            accountID: configuration.accountID,
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            bindPolicy: bindPolicy,
            managedRelayURLs: managedRelays,
            endpointRelayProfile: endpointRelayProfile,
            cachedHostPolicy: cachedHostPolicy
        )
    }

    func cachedPolicyFixture(
        binding: CmxIrohBrokerBindingMetadata? = nil
    ) throws -> HostPolicyCacheTestFixture {
        try HostPolicyCacheTestFixture(
            binding: binding ?? CmxIrohBrokerBindingMetadata(binding: self.binding),
            pairingEnabled: self.binding.pairingEnabled,
            capabilities: self.binding.capabilities
        )
    }

    func pendingRevocations() -> CmxIrohPendingRevocationOutbox {
        CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
    }

    static let relayURLs = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    static func binding(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010",
        publicHintObservedAt: Date? = nil,
        publicHintExpiresAt: Date? = nil
    ) throws -> CmxIrohBrokerBinding {
        try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: bindingJSON(
                endpointID: endpointID,
                bindingID: bindingID,
                publicHintObservedAt: publicHintObservedAt,
                publicHintExpiresAt: publicHintExpiresAt
            )
        )
    }

    static func discovery(
        binding: CmxIrohBrokerBinding,
        relays: [String],
        overrideDeviceID: String? = nil,
        routeContractVersion: Int = 1,
        lanGeneration: Int = 1
    ) throws -> CmxIrohDiscoveryResponse {
        var bindingObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(binding)
        ) as? [String: Any] ?? [:]
        bindingObject["device_id"] = overrideDeviceID ?? binding.deviceID
        let object: [String: Any] = [
            "route_contract_version": routeContractVersion,
            "bindings": [bindingObject],
            "relay_fleet": relays,
            "lan_rendezvous": [
                "generation": lanGeneration,
                "key": Data(repeating: 0, count: 32).base64URL,
            ],
            "grant_verification_keys": [
                "version": 1,
                "current_kid": "test-key",
                "keys": [[
                    "kid": "test-key",
                    "alg": "EdDSA",
                    "spki_der_base64": "AA==",
                ]],
            ],
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func bindingJSON(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010",
        deviceID: String = "123e4567-e89b-42d3-a456-426614174011",
        publicHintObservedAt: Date? = nil,
        publicHintExpiresAt: Date? = nil
    ) throws -> Data {
        let pathHints: [[String: Any]]
        if let publicHintObservedAt, let publicHintExpiresAt {
            pathHints = [[
                "kind": "relay_url",
                "value": "https://use1-1.relay.lawrence.cmux.iroh.link/",
                "source": "native",
                "privacy_scope": "public_internet",
                "observed_at": publicHintObservedAt.timeIntervalSinceReferenceDate,
                "expires_at": publicHintExpiresAt.timeIntervalSinceReferenceDate,
            ]]
        } else {
            pathHints = []
        }
        return try JSONSerialization.data(withJSONObject: [
            "binding_id": bindingID,
            "device_id": deviceID,
            "app_instance_id": "123e4567-e89b-42d3-a456-426614174012",
            "tag": "cmux-ios-v0",
            "platform": "mac",
            "display_name": "Test Mac",
            "endpoint_id": endpointID,
            "identity_generation": 4,
            "pairing_enabled": true,
            "capabilities": ["rpc", "multistream"],
            "path_hints": pathHints,
            "last_seen_at": "2026-07-09T12:00:00.000Z",
        ])
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
