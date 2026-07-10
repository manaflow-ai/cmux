import CryptoKit
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRegistryContextProviderTests {
    @Test
    func policyEligibleFallbacksSurviveUnusableRegistryHintFlood() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: "tailnet-a"
        )
        let managedRelay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet
        )
        let tailscale = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(30 * 60),
            networkProfile: profile
        )
        let unusableRegistryHints = try (0 ..< CmxAttachEndpoint.maximumIrohPathHintCount).map {
            try CmxIrohPathHint(
                kind: .relayURL,
                value: "https://unmanaged-\($0).example.com/",
                source: .native,
                privacyScope: .publicInternet
            )
        }
        let discovery = try fixture.discovery(targetHints: unusableRegistryHints)
        let response = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [response]
        )
        let supervisor = try await fixture.activeSupervisor()
        let provider = CmxIrohRegistryContextProvider(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [profile] },
            now: { fixture.now }
        )
        let route = try fixture.route(hints: [managedRelay, tailscale])

        let context = try await provider.context(for: route)

        #expect(context.dialPlan.publicPaths == [managedRelay])
        #expect(context.dialPlan.privateFallbackPaths == [tailscale])
        #expect(context.credential.kind == .pairGrant)
        #expect(context.credential.pairGrantToken == response.grant)
        #expect(await broker.observedPairGrantRequests() == [
            .init(
                initiatorBindingID: fixture.initiator.bindingID,
                acceptorBindingID: fixture.acceptor.bindingID
            ),
        ])
    }

    @Test
    func signedExpiryDrivesCacheRefreshBoundary() async throws {
        let fixture = try RegistryFixture()
        let clock = TestRegistryClock(fixture.now)
        let refreshedAt = fixture.now.addingTimeInterval(4 * 24 * 60 * 60 + 1)
        let refreshedSeconds = Int64(refreshedAt.timeIntervalSince1970)
        let first = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let second = try fixture.pairGrantResponse(
            issuedAt: refreshedSeconds,
            expiresAt: refreshedSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [first, second]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { clock.value() }
        )
        let route = try fixture.route(hints: [])

        #expect(try await provider.context(for: route).credential.pairGrantToken == first.grant)
        #expect(try await provider.context(for: route).credential.pairGrantToken == first.grant)
        #expect(await broker.pairGrantRequestCount() == 1)

        clock.set(refreshedAt)
        #expect(try await provider.context(for: route).credential.pairGrantToken == second.grant)
        #expect(await broker.pairGrantRequestCount() == 2)
    }

    @Test
    func responseExpiryMustMatchSignedGrantExpiry() async throws {
        let fixture = try RegistryFixture()
        let signedExpiry = fixture.nowSeconds + 7 * 24 * 60 * 60
        let token = try fixture.pairGrant(
            issuedAt: fixture.nowSeconds,
            expiresAt: signedExpiry
        )
        let inconsistent = try fixture.pairGrantResponse(
            token: token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(signedExpiry + 60))
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [inconsistent]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohRegistryContextError.invalidGrantExpiry) {
            try await provider.context(for: fixture.route(hints: []))
        }
    }

    @Test
    func discoveryMustPublishTheExactConfiguredRelayFleet() async throws {
        let fixture = try RegistryFixture()
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                relayFleet: [fixture.relayURL, "https://unexpected.example.com/"]
            ),
            pairGrantResponses: []
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohRegistryContextError.relayFleetMismatch) {
            try await provider.context(for: fixture.route(hints: []))
        }
        #expect(await broker.pairGrantRequestCount() == 0)
    }
}

private actor TestIrohRegistryBroker: CmxIrohRegistryServing {
    struct PairGrantRequest: Equatable, Sendable {
        let initiatorBindingID: String
        let acceptorBindingID: String
    }

    private let discoveryResponse: CmxIrohDiscoveryResponse
    private var responses: [CmxIrohPairGrantResponse]
    private var pairGrantRequests: [PairGrantRequest] = []

    init(
        discovery: CmxIrohDiscoveryResponse,
        pairGrantResponses: [CmxIrohPairGrantResponse]
    ) {
        discoveryResponse = discovery
        responses = pairGrantResponses
    }

    func discover() -> CmxIrohDiscoveryResponse {
        discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) throws -> CmxIrohPairGrantResponse {
        pairGrantRequests.append(.init(
            initiatorBindingID: initiatorBindingID,
            acceptorBindingID: acceptorBindingID
        ))
        guard !responses.isEmpty else { throw TestRegistryError.noGrantResponse }
        return responses.removeFirst()
    }

    func observedPairGrantRequests() -> [PairGrantRequest] {
        pairGrantRequests
    }

    func pairGrantRequestCount() -> Int {
        pairGrantRequests.count
    }
}

private final class TestRegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}

private enum TestRegistryError: Error {
    case noGrantResponse
}

private struct RegistryFixture: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let key: CmxIrohGrantVerificationKey
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds: Int64 = 1_800_000_000
    let relayURL = "https://use1-1.relay.lawrence.cmux.iroh.link/"

    init() throws {
        privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0 ..< 32).map(UInt8.init))
        )
        let targetKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        initiator = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "ios",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: privateKey.publicKey.rawRepresentation.registryHex
            ),
            identityGeneration: 1
        )
        acceptor = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174003",
            deviceID: "123e4567-e89b-42d3-a456-426614174004",
            tag: "mac",
            platform: .mac,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: targetKey.publicKey.rawRepresentation.registryHex
            ),
            identityGeneration: 2
        )
        let prefix = Data([
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
            0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        key = CmxIrohGrantVerificationKey(
            kid: "current",
            alg: "EdDSA",
            spkiDerBase64: (prefix + privateKey.publicKey.rawRepresentation).base64EncodedString()
        )
    }

    func activeSupervisor() async throws -> CmxIrohEndpointSupervisor {
        let endpoint = TestIrohEndpoint(identity: initiator.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 4, count: 32)),
            alpns: [Data("cmux/mobile/1".utf8)],
            managedRelayURLs: [relayURL],
            relays: []
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: configuration
        )
        _ = try await supervisor.activate()
        return supervisor
    }

    func route(hints: [CmxIrohPathHint]) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh-primary",
            kind: .iroh,
            endpoint: .peer(identity: acceptor.endpointID, pathHints: hints)
        )
    }

    func discovery(
        targetHints: [CmxIrohPathHint],
        relayFleet: [String]? = nil
    ) throws -> CmxIrohDiscoveryResponse {
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": [
                try bindingObject(
                    peer: initiator,
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174005",
                    pairingEnabled: false,
                    hints: []
                ),
                try bindingObject(
                    peer: acceptor,
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174006",
                    pairingEnabled: true,
                    hints: targetHints
                ),
            ],
            "relay_fleet": relayFleet ?? [relayURL],
            "lan_rendezvous": ["generation": 1, "key": "opaque-test-key"],
            "grant_verification_keys": [
                "version": 1,
                "current_kid": key.kid,
                "keys": [[
                    "kid": key.kid,
                    "alg": key.alg,
                    "spki_der_base64": key.spkiDerBase64,
                ]],
            ],
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    func pairGrantResponse(
        issuedAt: Int64,
        expiresAt: Int64
    ) throws -> CmxIrohPairGrantResponse {
        try pairGrantResponse(
            token: pairGrant(issuedAt: issuedAt, expiresAt: expiresAt),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt))
        )
    }

    func pairGrantResponse(
        token: String,
        expiresAt: Date
    ) throws -> CmxIrohPairGrantResponse {
        let object = [
            "grant": token,
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
        ]
        return try JSONDecoder().decode(
            CmxIrohPairGrantResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    func pairGrant(issuedAt: Int64, expiresAt: Int64) throws -> String {
        let claims: [String: Any] = [
            "jti": UUID().uuidString.lowercased(),
            "iat": issuedAt,
            "nbf": issuedAt - 5,
            "exp": expiresAt,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": peerObject(initiator),
            "acceptor": peerObject(acceptor),
        ]
        let header = try JSONSerialization.data(
            withJSONObject: ["alg": "EdDSA", "typ": "cmux-pair-grant+jwt", "kid": key.kid],
            options: [.sortedKeys]
        ).registryBase64URL
        let payload = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ).registryBase64URL
        let signingInput = "\(header).\(payload)"
        let signature = try privateKey.signature(
            for: Data(signingInput.utf8)
        ).registryBase64URL
        return "\(signingInput).\(signature)"
    }

    private func bindingObject(
        peer: CmxIrohGrantPeer,
        appInstanceID: String,
        pairingEnabled: Bool,
        hints: [CmxIrohPathHint]
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let hintObjects = try hints.map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        }
        return [
            "binding_id": peer.bindingID,
            "device_id": peer.deviceID,
            "app_instance_id": appInstanceID,
            "tag": peer.tag,
            "platform": peer.platform.rawValue,
            "endpoint_id": peer.endpointID.endpointID,
            "identity_generation": peer.identityGeneration,
            "pairing_enabled": pairingEnabled,
            "capabilities": ["multistream-v1"],
            "path_hints": hintObjects,
            "last_seen_at": ISO8601DateFormatter().string(from: now),
        ]
    }

    private func peerObject(_ peer: CmxIrohGrantPeer) -> [String: Any] {
        [
            "bindingId": peer.bindingID,
            "deviceId": peer.deviceID,
            "tag": peer.tag,
            "platform": peer.platform.rawValue,
            "endpointId": peer.endpointID.endpointID,
            "identityGeneration": peer.identityGeneration,
        ]
    }
}

private extension Data {
    var registryBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var registryHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
