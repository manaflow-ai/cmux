import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohHostRuntimeTests {
    @Test
    func startBindsExactRegisteredIdentityAndStopClosesIt() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            handleTransport: { transport, _, _ in await transport.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )

        try await runtime.start()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        #expect(await broker.observedRegistrationCount() == 1)
        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 1)
        #expect(configurations.first?.secretKey == fixture.identity.secretKey)
        #expect(configurations.first?.managedRelayURLs == fixture.managedRelays)

        await runtime.stop()

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func discoverySubstitutionFailsClosedAndClosesEndpoint() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let substituted = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            overrideDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: substituted
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            handleTransport: { transport, _, _ in await transport.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }
}

private struct HostRuntimeFixture {
    let identity: CmxIrohIdentityMaterial
    let endpointID: CmxIrohPeerIdentity
    let binding: CmxIrohBrokerBinding
    let discovery: CmxIrohDiscoveryResponse
    let managedRelays: Set<String>
    let configuration: CmxIrohHostRuntimeConfiguration

    init() throws {
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
        binding = try Self.binding(endpointID: endpointID.endpointID)
        discovery = try Self.discovery(
            binding: binding,
            relays: Self.relayURLs
        )
        configuration = CmxIrohHostRuntimeConfiguration(
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

    static let relayURLs = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    static func binding(endpointID: String) throws -> CmxIrohBrokerBinding {
        try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: bindingJSON(endpointID: endpointID)
        )
    }

    static func discovery(
        binding: CmxIrohBrokerBinding,
        relays: [String],
        overrideDeviceID: String? = nil
    ) throws -> CmxIrohDiscoveryResponse {
        let bindingObject = try JSONSerialization.jsonObject(
            with: bindingJSON(
                endpointID: binding.endpointID.endpointID,
                deviceID: overrideDeviceID ?? binding.deviceID
            )
        )
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": [bindingObject],
            "relay_fleet": relays,
            "lan_rendezvous": [
                "generation": 1,
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
        deviceID: String = "123e4567-e89b-42d3-a456-426614174011"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "binding_id": "123e4567-e89b-42d3-a456-426614174010",
            "device_id": deviceID,
            "app_instance_id": "123e4567-e89b-42d3-a456-426614174012",
            "tag": "cmux-ios-v0",
            "platform": "mac",
            "display_name": "Test Mac",
            "endpoint_id": endpointID,
            "identity_generation": 4,
            "pairing_enabled": true,
            "capabilities": ["rpc", "multistream"],
            "path_hints": [],
            "last_seen_at": "2026-07-09T12:00:00.000Z",
        ])
    }
}

private actor TestIrohHostBroker: CmxIrohHostBrokerServing {
    private let registrationBinding: CmxIrohBrokerBinding
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private var registrationCount = 0

    init(
        registrationBinding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse
    ) {
        self.registrationBinding = registrationBinding
        discoveryResponse = discovery
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) -> CmxIrohRegistrationResponse {
        registrationCount += 1
        return CmxIrohRegistrationResponse(
            binding: registrationBinding,
            relay: .unavailable
        )
    }

    func discover() -> CmxIrohDiscoveryResponse { discoveryResponse }

    func issueEndpointAttestation(
        bindingID _: String
    ) throws -> CmxIrohEndpointAttestationResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(bindingID _: String) -> CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-07-10T12:00:00.000Z",
            refreshAfter: "2027-07-10T11:00:00.000Z",
            relayFleet: HostRuntimeFixture.relayURLs
        )
    }

    func revoke(bindingID _: String) {}

    func observedRegistrationCount() -> Int { registrationCount }
}

private actor HostRuntimeDeactivationRecorder {
    private var recorded: [String?] = []

    func record(_ bindingID: String?) { recorded.append(bindingID) }
    func values() -> [String?] { recorded }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
