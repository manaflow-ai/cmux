import CMUXMobileCore
import CryptoKit
import Foundation
@testable import CmuxIrohTransport

struct ClientRuntimeTestFixture {
    static let relayURLs = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    let identity: CmxIrohIdentityMaterial
    let endpointID: CmxIrohPeerIdentity
    let binding: CmxIrohBrokerBinding
    let discovery: CmxIrohDiscoveryResponse
    let configuration: CmxIrohClientRuntimeConfiguration
    let now = Date(timeIntervalSince1970: 1_783_686_000)

    init() throws {
        let secret = Data(repeating: 0x41, count: 32)
        identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: secret),
            generation: 3
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        endpointID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        binding = try Self.binding(endpointID: endpointID.endpointID)
        discovery = try Self.discovery(binding: binding)
        configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            capabilities: binding.capabilities,
            managedRelayURLs: Set(Self.relayURLs)
        )
    }

    func relayResponse() -> CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-07-10T12:00:00.000Z",
            refreshAfter: "2027-07-10T11:00:00.000Z",
            relayFleet: Self.relayURLs
        )
    }

    func pendingRevocations() -> CmxIrohPendingRevocationOutbox {
        CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
    }

    static func binding(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174020",
        deviceID: String = "123e4567-e89b-42d3-a456-426614174021",
        appInstanceID: String = "123e4567-e89b-42d3-a456-426614174022"
    ) throws -> CmxIrohBrokerBinding {
        try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: bindingJSON(
                endpointID: endpointID,
                bindingID: bindingID,
                deviceID: deviceID,
                appInstanceID: appInstanceID
            )
        )
    }

    static func discovery(
        binding: CmxIrohBrokerBinding,
        overrideAppInstanceID: String? = nil,
        relayURLs: [String] = relayURLs
    ) throws -> CmxIrohDiscoveryResponse {
        let bindingObject = try JSONSerialization.jsonObject(
            with: bindingJSON(
                endpointID: binding.endpointID.endpointID,
                bindingID: binding.bindingID,
                deviceID: binding.deviceID,
                appInstanceID: overrideAppInstanceID ?? binding.appInstanceID
            )
        )
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": [bindingObject],
            "relay_fleet": relayURLs,
            "lan_rendezvous": [
                "generation": 1,
                "key": Data(repeating: 0, count: 32).clientRuntimeBase64URL,
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
        bindingID: String,
        deviceID: String,
        appInstanceID: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "binding_id": bindingID,
            "device_id": deviceID,
            "app_instance_id": appInstanceID,
            "tag": "cmux-ios-v0",
            "platform": "ios",
            "display_name": "Test iPhone",
            "endpoint_id": endpointID,
            "identity_generation": 3,
            "pairing_enabled": false,
            "capabilities": ["mobile-rpc-v1", "multistream-v1"],
            "path_hints": [],
            "last_seen_at": "2026-07-10T12:00:00.000Z",
        ])
    }
}

private extension Data {
    var clientRuntimeBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
