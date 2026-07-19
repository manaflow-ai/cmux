@preconcurrency import CryptoKit
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

func opaqueProfileID(_ label: String) -> String {
    SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite
struct CmxIrohRegistryContextProviderTests {
    @Test
    func authenticatedDirectPortsReplaceLegacyTailscaleTCPPorts() async throws {
        let fixture = try RegistryFixture()
        let profile = CmxIrohNetworkProfileKey.activeTailscaleTunnel
        let expiresAt = fixture.now.addingTimeInterval(60)
        let ipv4 = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.82.214.112:53646",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: expiresAt,
            networkProfile: profile
        )
        let ipv6 = try CmxIrohPathHint(
            kind: .directAddress,
            value: "[fd7a:115c:a1e0::4b36:d670]:53646",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: expiresAt,
            networkProfile: profile
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": 50_909, "ipv6": 54_750]
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 1,
                    activeNetworkProfiles: [profile]
                )
            },
            now: { fixture.now }
        )

        let context = try await provider.context(
            for: fixture.request(hints: [ipv4, ipv6])
        )

        #expect(context.dialPlan.privateFallbackPaths.map(\.value) == [
            "100.82.214.112:50909",
            "[fd7a:115c:a1e0::4b36:d670]:54750",
        ])
    }

    @Test
    func missingStaleOrWrongFamilyPortsCannotAuthorizePrivatePortGuessing() async throws {
        let fixture = try RegistryFixture()
        let profile = CmxIrohNetworkProfileKey.activeTailscaleTunnel
        let managedRelay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet
        )
        let tailscale = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.82.214.112:53646",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60),
            networkProfile: profile
        )
        let stale = fixture.now.addingTimeInterval(
            -(CmxIrohPathHint.maximumPrivateHintTTL + 1)
        )
        let cases: [(String, [String: Int]?, Date?)] = [
            ("missing", nil, nil),
            ("wrong family", ["ipv6": 54_750], nil),
            ("stale", ["ipv4": 50_909], stale),
        ]

        for (name, directPorts, lastSeenAt) in cases {
            let broker = TestIrohRegistryBroker(
                discovery: try fixture.discovery(
                    targetHints: [],
                    targetDirectPorts: directPorts,
                    targetLastSeenAt: lastSeenAt
                ),
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                )]
            )
            let provider = CmxIrohRegistryContextProvider(
                supervisor: try await fixture.activeSupervisor(),
                broker: broker,
                localBindingExpectation: try fixture.localExpectation(),
                managedRelayURLs: [fixture.relayURL],
                networkPathSnapshot: {
                    CmxIrohNetworkPathSnapshot(
                        generation: 1,
                        activeNetworkProfiles: [profile]
                    )
                },
                now: { fixture.now }
            )

            let context = try await provider.context(
                for: fixture.request(hints: [managedRelay, tailscale])
            )

            #expect(context.dialPlan.publicPaths == [managedRelay], Comment(rawValue: name))
            #expect(context.dialPlan.privateFallbackPaths.isEmpty, Comment(rawValue: name))
            #expect(context.privateFallbackAuthorization == nil, Comment(rawValue: name))
        }
    }

    @Test
    func bonjourFallbackAcceptsLegacyUppercaseDeviceUUID() async throws {
        let fixture = try RegistryFixture()
        let relay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet
        )
        let profile = try CmxIrohNetworkProfileKey(
            source: .lan,
            profileID: opaqueProfileID("bonjour-profile")
        )
        let lanHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "192.168.1.10:50906",
            source: .lan,
            privacyScope: .localNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60),
            networkProfile: profile
        )
        let recorder = TestLANFallbackRecorder(hints: [lanHint])
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 23,
                    activeNetworkProfiles: [profile]
                )
            },
            lanFallback: { target, bindings, rendezvous in
                await recorder.provide(
                    target: target,
                    bindings: bindings,
                    rendezvous: rendezvous
                )
            },
            now: { fixture.now }
        )
        let request = try fixture.request(
            hints: [relay],
            expectedPeerDeviceID: fixture.acceptor.deviceID.uppercased()
        )
        let publicContext = try await provider.context(for: request)

        #expect(await recorder.callCount() == 0)
        #expect(publicContext.dialPlan.publicPaths == [relay])
        #expect(publicContext.dialPlan.privateFallbackPaths.isEmpty)

        let fallbackContext = try await provider.contextWithPrivateFallback(
            for: request,
            basedOn: publicContext
        )

        #expect(await recorder.callCount() == 1)
        #expect(await recorder.lastTarget() == fixture.acceptor.endpointID)
        #expect(await recorder.lastBindingCount() == 2)
        #expect(fallbackContext.dialPlan.publicPaths == [relay])
        #expect(fallbackContext.dialPlan.privateFallbackPaths == [lanHint])
        let authorization = try #require(fallbackContext.privateFallbackAuthorization)
        #expect(authorization.networkPathSnapshot.generation == 23)
        #expect(authorization.pathHints == [lanHint])
    }
}
enum TestRegistryBrokerFailure: CaseIterable, CustomStringConvertible {
    case tls
    case decode

    var error: any Error {
        switch self {
        case .tls: URLError(.serverCertificateUntrusted)
        case .decode: CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    var description: String {
        switch self {
        case .tls: "TLS failure"
        case .decode: "decode failure"
        }
    }
}

actor TestIrohRegistryBroker: CmxIrohRegistryServing {
    struct PairGrantRequest: Equatable, Sendable {
        let initiatorBindingID: String
        let acceptorBindingID: String
    }

    private var discoveryResponse: CmxIrohDiscoveryResponse
    private var responses: [CmxIrohPairGrantResponse]
    private var pairGrantRequests: [PairGrantRequest] = []
    private let discoveryError: (any Error)?
    private let pairGrantError: (any Error)?

    init(
        discovery: CmxIrohDiscoveryResponse,
        pairGrantResponses: [CmxIrohPairGrantResponse],
        discoveryError: (any Error)? = nil,
        pairGrantError: (any Error)? = nil
    ) {
        discoveryResponse = discovery
        responses = pairGrantResponses
        self.discoveryError = discoveryError
        self.pairGrantError = pairGrantError
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        if let discoveryError { throw discoveryError }
        return discoveryResponse
    }

    func setDiscovery(_ discovery: CmxIrohDiscoveryResponse) {
        discoveryResponse = discovery
    }

    func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) throws -> CmxIrohPairGrantResponse {
        pairGrantRequests.append(.init(
            initiatorBindingID: initiatorBindingID,
            acceptorBindingID: acceptorBindingID
        ))
        if let pairGrantError { throw pairGrantError }
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

actor TestLANFallbackRecorder {
    private let hints: [CmxIrohPathHint]
    private var targets: [CmxIrohPeerIdentity] = []
    private var bindingCounts: [Int] = []

    init(hints: [CmxIrohPathHint]) {
        self.hints = hints
    }

    func provide(
        target: CmxIrohBrokerBindingMetadata,
        bindings: [CmxIrohBrokerBindingMetadata],
        rendezvous _: CmxIrohLANRendezvous
    ) -> [CmxIrohPathHint] {
        targets.append(target.endpointID)
        bindingCounts.append(bindings.count)
        return hints
    }

    func callCount() -> Int { targets.count }
    func lastTarget() -> CmxIrohPeerIdentity? { targets.last }
    func lastBindingCount() -> Int? { bindingCounts.last }
}

final class TestRegistryClock: @unchecked Sendable {
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

enum TestRegistryError: Error {
    case noGrantResponse
}

actor TestNetworkPathState {
    private var snapshot: CmxIrohNetworkPathSnapshot?

    init(snapshot: CmxIrohNetworkPathSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() throws -> CmxIrohNetworkPathSnapshot {
        guard let snapshot else { throw TestNetworkPathStateError.unavailable }
        return snapshot
    }

    func setSnapshot(_ snapshot: CmxIrohNetworkPathSnapshot) {
        self.snapshot = snapshot
    }

    func setUnavailable() {
        snapshot = nil
    }
}

enum TestNetworkPathStateError: Error {
    case unavailable
}

struct RegistryFixture: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let acceptorSecretKey: Data
    let key: CmxIrohGrantVerificationKey
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let now: Date
    let nowSeconds: Int64
    let relayURL = "https://use1-1.relay.lawrence.cmux.iroh.link/"

    init(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        initiatorSecretKey: Data = Data((0 ..< 32).map(UInt8.init)),
        acceptorSecretKey: Data = Data(repeating: 9, count: 32)
    ) throws {
        self.now = now
        self.acceptorSecretKey = acceptorSecretKey
        nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: initiatorSecretKey
        )
        let targetKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: acceptorSecretKey
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

    func localExpectation() throws -> CmxIrohLocalBindingExpectation {
        try CmxIrohLocalBindingExpectation(
            deviceID: initiator.deviceID,
            appInstanceID: "123e4567-e89b-42d3-a456-426614174005",
            tag: initiator.tag,
            platform: initiator.platform,
            endpointID: initiator.endpointID,
            identityGeneration: initiator.identityGeneration,
            pairingEnabled: false,
            capabilities: ["multistream-v1"]
        )
    }

    func offlineExpectation(
        accountID: String = "account-a",
        localExpectation: CmxIrohLocalBindingExpectation? = nil,
        managedRelayURLs: Set<String>? = nil
    ) throws -> CmxIrohClientOfflinePolicyExpectation {
        try CmxIrohClientOfflinePolicyExpectation(
            accountID: accountID,
            localBindingExpectation: localExpectation ?? self.localExpectation(),
            managedRelayURLs: managedRelayURLs ?? [relayURL]
        )
    }

    func route(hints: [CmxIrohPathHint]) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh-primary",
            kind: .iroh,
            endpoint: .peer(identity: acceptor.endpointID, pathHints: hints)
        )
    }

    func request(
        hints: [CmxIrohPathHint],
        expectedPeerDeviceID: String? = nil
    ) throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try route(hints: hints),
            expectedPeerDeviceID: expectedPeerDeviceID ?? acceptor.deviceID,
            authorizationMode: .transportAdmission
        )
    }

    func discovery(
        targetHints: [CmxIrohPathHint],
        targetDirectPorts: [String: Int]? = nil,
        targetLastSeenAt: Date? = nil,
        relayFleet: [String]? = nil,
        localAppInstanceID: String = "123e4567-e89b-42d3-a456-426614174005",
        targetDeviceID: String? = nil,
        includeTarget: Bool = true
    ) throws -> CmxIrohDiscoveryResponse {
        var bindings: [[String: Any]] = [
            try bindingObject(
                peer: initiator,
                appInstanceID: localAppInstanceID,
                pairingEnabled: false,
                hints: []
            ),
        ]
        if includeTarget {
            var target = try bindingObject(
                peer: CmxIrohGrantPeer(
                    bindingID: acceptor.bindingID,
                    deviceID: targetDeviceID ?? acceptor.deviceID,
                    tag: acceptor.tag,
                    platform: acceptor.platform,
                    endpointID: acceptor.endpointID,
                    identityGeneration: acceptor.identityGeneration
                ),
                appInstanceID: "123e4567-e89b-42d3-a456-426614174006",
                pairingEnabled: true,
                hints: targetHints
            )
            if let targetDirectPorts {
                target["direct_ports"] = targetDirectPorts
            }
            if let targetLastSeenAt {
                target["last_seen_at"] = ISO8601DateFormatter().string(
                    from: targetLastSeenAt
                )
            }
            bindings.append(target)
        }
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": bindings,
            "relay_fleet": relayFleet ?? [relayURL],
            "lan_rendezvous": [
                "generation": 1,
                "key": Data(repeating: 7, count: 32).registryBase64URL,
            ],
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
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
        encoder.dateEncodingStrategy = .iso8601
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
