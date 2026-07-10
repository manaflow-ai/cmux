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
            handleTransport: { session, _ in await session.close() },
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
        #expect(configurations.first?.bindPolicy == .ephemeral)
        #expect(configurations.first?.managedRelayURLs == fixture.managedRelays)

        await runtime.stop()

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func requiredBindPolicyIsForwardedToTheEndpointGeneration() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindAddress = try CmxIrohBindAddress(
            ipAddress: "127.0.0.1",
            port: 4_444
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                bindPolicy: .required(bindAddress)
            ),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(
            await factory.observedConfigurations().first?.bindPolicy
                == .required(bindAddress)
        )
        await runtime.stop()
    }

    @Test
    func connectivityFailureUsesVerifiedCacheOnlyAfterOnlineAttempt() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let cachedPolicy = try cachedFixture.policy()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(cachedHostPolicy: cachedPolicy),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().bindingID == cachedPolicy.binding.bindingID)
        #expect(await bindings.count() == 0)
        await runtime.stop()
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.missingAuthentication,
        .rejected(statusCode: 503, code: "unavailable"),
        .invalidResponse,
    ])
    func terminalBrokerFailureNeverUsesCachedPolicy(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: failure
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        do {
            try await runtime.start()
            Issue.record("Expected terminal broker failure")
        } catch let error as CmxIrohTrustBrokerClientError {
            #expect(error == failure)
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func onlinePolicySupersedesAValidCachedBinding() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedMetadata = try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174099",
            deviceID: fixture.binding.deviceID,
            appInstanceID: fixture.binding.appInstanceID,
            tag: fixture.binding.tag,
            platform: .mac,
            endpointID: fixture.binding.endpointID,
            identityGeneration: fixture.binding.identityGeneration
        )
        let cachedFixture = try fixture.cachedPolicyFixture(binding: cachedMetadata)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().bindingID == fixture.binding.bindingID)
        #expect(await bindings.count() == 1)
        await runtime.stop()
    }

    @Test
    func forgedCachedPolicyFailsAfterConnectivityFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policySignedByOriginalKey(
                    publishedKeySet: cachedFixture.alternateKeySet
                )
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohGrantVerifierError.invalidSignature) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func confirmedOnlineBindingChangePreventsDiscoveryConnectivityFallback() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let changedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: changedBinding,
            discovery: fixture.discovery,
            discoveryError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func routeContractMismatchNeverUsesCachedPolicy() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let mismatchedDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            routeContractVersion: 2
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: mismatchedDiscovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.routeContractMismatch) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
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
        let cachedFixture = try fixture.cachedPolicyFixture()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
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

    func configuration(
        cachedHostPolicy: CmxIrohCachedHostPolicy? = nil,
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral
    ) -> CmxIrohHostRuntimeConfiguration {
        CmxIrohHostRuntimeConfiguration(
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            bindPolicy: bindPolicy,
            managedRelayURLs: managedRelays,
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

    static let relayURLs = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    static func binding(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010"
    ) throws -> CmxIrohBrokerBinding {
        try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: bindingJSON(endpointID: endpointID, bindingID: bindingID)
        )
    }

    static func discovery(
        binding: CmxIrohBrokerBinding,
        relays: [String],
        overrideDeviceID: String? = nil,
        routeContractVersion: Int = 1
    ) throws -> CmxIrohDiscoveryResponse {
        let bindingObject = try JSONSerialization.jsonObject(
            with: bindingJSON(
                endpointID: binding.endpointID.endpointID,
                bindingID: binding.bindingID,
                deviceID: overrideDeviceID ?? binding.deviceID
            )
        )
        let object: [String: Any] = [
            "route_contract_version": routeContractVersion,
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
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010",
        deviceID: String = "123e4567-e89b-42d3-a456-426614174011"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
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
            "path_hints": [],
            "last_seen_at": "2026-07-09T12:00:00.000Z",
        ])
    }
}

private actor TestIrohHostBroker: CmxIrohHostBrokerServing {
    private let registrationBinding: CmxIrohBrokerBinding
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let registrationError: CmxIrohTrustBrokerClientError?
    private let discoveryError: CmxIrohTrustBrokerClientError?
    private var registrationCount = 0

    init(
        registrationBinding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        registrationError: CmxIrohTrustBrokerClientError? = nil,
        discoveryError: CmxIrohTrustBrokerClientError? = nil
    ) {
        self.registrationBinding = registrationBinding
        discoveryResponse = discovery
        self.registrationError = registrationError
        self.discoveryError = discoveryError
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) throws -> CmxIrohRegistrationResponse {
        registrationCount += 1
        if let registrationError { throw registrationError }
        return CmxIrohRegistrationResponse(
            binding: registrationBinding,
            relay: .unavailable
        )
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        if let discoveryError { throw discoveryError }
        return discoveryResponse
    }

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

private actor HostRuntimeBindingRecorder {
    private var recordedCount = 0

    func record() { recordedCount += 1 }
    func count() -> Int { recordedCount }
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
