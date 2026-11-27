import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRelayPolicyTests {
    @Test
    func appPinnedTrustRootAcceptsCurrentAndStagedNextKeys() throws {
        let current = Curve25519.Signing.PrivateKey()
        let next = Curve25519.Signing.PrivateKey()
        let trustRoot = CmxIrohRelayPolicyTrustRoot.appPinned(infoDictionary: [
            "CMUXIrohRelayPolicyTrustKeys": [
                [
                    "keyID": "policy-current",
                    "publicKeyBase64": current.publicKey.rawRepresentation.base64EncodedString(),
                ],
                [
                    "keyID": "policy-next",
                    "publicKeyBase64": next.publicKey.rawRepresentation.base64EncodedString(),
                ],
            ],
        ])

        #expect(trustRoot?.keys.map(\.keyID) == ["policy-current", "policy-next"])
    }

    @Test
    func appPinnedTrustRootFailsClosedForPartialRotationConfiguration() throws {
        let current = Curve25519.Signing.PrivateKey()
        let trustRoot = CmxIrohRelayPolicyTrustRoot.appPinned(infoDictionary: [
            "CMUXIrohRelayPolicyTrustKeys": [
                [
                    "keyID": "policy-current",
                    "publicKeyBase64": current.publicKey.rawRepresentation.base64EncodedString(),
                ],
                ["keyID": "policy-next"],
            ],
            "CMUXIrohRelayPolicyKeyID": "policy-current",
            "CMUXIrohRelayPolicyPublicKeyBase64": current.publicKey.rawRepresentation
                .base64EncodedString(),
        ])

        #expect(trustRoot == nil)
    }

    @Test
    func signatureAuthorizesCatalogAndSelectionFiltersByStableID() throws {
        let fixture = try Fixture()
        let token = try fixture.token(sequence: 7)

        let policy = try CmxIrohRelayPolicyVerifier().verify(
            token,
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        let automatic = try CmxIrohRelayPolicySnapshot(
            policy: policy,
            selection: .automatic
        )
        #expect(automatic.relayURLs == Set(fixture.relayURLs))

        let selected = try CmxIrohRelayPolicySnapshot(
            policy: policy,
            selection: .only(["cmux-eu"])
        )
        #expect(selected.relays.map(\.id) == ["cmux-eu"])
        #expect(selected.relayURLs == [fixture.relayURLs[1]])
    }

    @Test
    func policyAcceptsServerDisplayLabelsAndExplicitHTTPSPorts() throws {
        let fixture = try Fixture()
        let token = try fixture.token(
            sequence: 8,
            relayURLs: [
                "https://usc1.relay.cmux.dev:8443/",
                fixture.relayURLs[1],
            ],
            regions: ["US Central", "Europe West"]
        )

        let policy = try CmxIrohRelayPolicyVerifier().verify(
            token,
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        #expect(policy.relays.map(\.region) == ["US Central", "Europe West"])
        #expect(policy.relays[0].url == "https://usc1.relay.cmux.dev:8443/")
    }

    @Test
    func substitutedRelayAndUnknownSelectionFailClosed() throws {
        let fixture = try Fixture()
        let valid = try fixture.token(sequence: 7)
        let segments = valid.split(separator: ".", omittingEmptySubsequences: false)
        let substitutedPayload = try fixture.payload(
            sequence: 7,
            relayURLs: [
                fixture.relayURLs[0],
                "https://capture.example.com/",
            ]
        )
        let substituted = [
            String(segments[0]),
            Fixture.base64URL(substitutedPayload),
            String(segments[2]),
        ].joined(separator: ".")

        #expect(throws: CmxIrohRelayPolicyError.invalidSignature) {
            try CmxIrohRelayPolicyVerifier().verify(
                substituted,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }

        let policy = try CmxIrohRelayPolicyVerifier().verify(
            valid,
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        #expect(throws: CmxIrohRelayPolicyError.invalidSelection) {
            try CmxIrohRelayPolicySnapshot(
                policy: policy,
                selection: .only(["removed-relay"])
            )
        }
    }

    @Test
    func policyTimeProtocolAndKeyIDAreStrict() throws {
        let fixture = try Fixture()
        let expired = try fixture.token(
            sequence: 1,
            expiresAt: fixture.nowSeconds + 60
        )
        #expect(throws: CmxIrohRelayPolicyError.expired) {
            try CmxIrohRelayPolicyVerifier().verify(
                expired,
                trustRoot: fixture.trustRoot,
                now: fixture.now.addingTimeInterval(60)
            )
        }

        let unsupported = try fixture.token(
            sequence: 2,
            relayProtocol: "iroh-relay-v2"
        )
        #expect(throws: CmxIrohRelayPolicyError.unsupportedRelayProtocol) {
            try CmxIrohRelayPolicyVerifier().verify(
                unsupported,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }

        let unknownKey = try fixture.token(sequence: 3, keyID: "future-key")
        #expect(throws: CmxIrohRelayPolicyError.unknownKeyID) {
            try CmxIrohRelayPolicyVerifier().verify(
                unknownKey,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }
    }

    @Test
    func policyAcceptsOnlyBoundedNotBeforeClockSkew() throws {
        let fixture = try Fixture()
        let tolerated = try fixture.token(
            sequence: 4,
            notBefore: fixture.nowSeconds + 30
        )

        #expect(throws: Never.self) {
            try CmxIrohRelayPolicyVerifier().verify(
                tolerated,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }

        let excessive = try fixture.token(
            sequence: 5,
            notBefore: fixture.nowSeconds + 31
        )
        #expect(throws: CmxIrohRelayPolicyError.invalidClaims) {
            try CmxIrohRelayPolicyVerifier().verify(
                excessive,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }
    }

    @Test
    func cacheRejectsPolicyRollbackAndReverifiesOnLoad() async throws {
        let fixture = try Fixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohRelayPolicyCache(secureStore: store)
        let sequenceSeven = try fixture.token(sequence: 7)

        let installed = try await cache.install(
            signedPolicy: sequenceSeven,
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        #expect(installed.sequence == 7)
        #expect(await store.observedAccessibilities() == [.afterFirstUnlockThisDeviceOnly])

        let sequenceSix = try fixture.token(sequence: 6)
        await #expect(throws: CmxIrohRelayPolicyError.rollback) {
            try await cache.install(
                signedPolicy: sequenceSix,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }
        let equivocatedSequenceSeven = try fixture.token(
            sequence: 7,
            relayURLs: [
                fixture.relayURLs[0],
                "https://alternate.relay.cmux.dev/",
            ]
        )
        await #expect(throws: CmxIrohRelayPolicyError.rollback) {
            try await cache.install(
                signedPolicy: equivocatedSequenceSeven,
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }
        let restored = try await cache.load(
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        #expect(restored?.sequence == 7)
    }

    @Test
    func cacheAcceptsRenewedEnvelopeForUnchangedCatalog() async throws {
        let fixture = try Fixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohRelayPolicyCache(secureStore: store)
        _ = try await cache.install(
            signedPolicy: fixture.token(sequence: 7),
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )

        let renewalTime = fixture.now.addingTimeInterval(120)
        let renewed = try fixture.token(
            sequence: 7,
            issuedAt: fixture.nowSeconds + 120,
            expiresAt: fixture.nowSeconds + 3_720
        )
        let installed = try await cache.install(
            signedPolicy: renewed,
            trustRoot: fixture.trustRoot,
            now: renewalTime
        )

        #expect(installed.sequence == 7)
        #expect(installed.issuedAt == fixture.nowSeconds + 120)
        #expect(
            try await cache.load(trustRoot: fixture.trustRoot, now: renewalTime)?.expiresAt
                == fixture.nowSeconds + 3_720
        )
    }

    @Test
    func corruptPolicyCacheCannotEraseTheRollbackFloor() async throws {
        let fixture = try Fixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohRelayPolicyCache(secureStore: store)
        _ = try await cache.install(
            signedPolicy: fixture.token(sequence: 7),
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        await store.write(
            Data("corrupt".utf8),
            account: "managed-relay-policy",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        await #expect(throws: CmxIrohRelayPolicyError.invalidClaims) {
            try await cache.load(trustRoot: fixture.trustRoot, now: fixture.now)
        }
        await #expect(throws: CmxIrohRelayPolicyError.invalidClaims) {
            try await cache.install(
                signedPolicy: fixture.token(sequence: 6),
                trustRoot: fixture.trustRoot,
                now: fixture.now
            )
        }
        #expect(await store.recordCount() == 1)
    }

    @Test
    func endpointProfileRequiresExactCredentialsForVerifiedSelection() throws {
        let fixture = try Fixture()
        let policy = try CmxIrohRelayPolicyVerifier().verify(
            fixture.token(sequence: 7),
            trustRoot: fixture.trustRoot,
            now: fixture.now
        )
        let snapshot = try CmxIrohRelayPolicySnapshot(
            policy: policy,
            selection: .only(["cmux-eu"])
        )
        let selected = try fixture.relayConfiguration(url: fixture.relayURLs[1])
        let profile = try CmxIrohEndpointRelayProfile(
            snapshot: snapshot,
            relays: [selected]
        )

        #expect(profile.allowedRelayURLs == [fixture.relayURLs[1]])
        #expect(profile.managedRelays == [selected])
        #expect(throws: CmxIrohEndpointConfigurationError.incompleteManagedRelayCredentials) {
            try CmxIrohEndpointRelayProfile(snapshot: snapshot, relays: [])
        }
        let substituted = try fixture.relayConfiguration(
            url: "https://capture.example.com/"
        )
        #expect(
            throws: CmxIrohEndpointConfigurationError.unmanagedRelayURL(substituted.url)
        ) {
            try CmxIrohEndpointRelayProfile(snapshot: snapshot, relays: [substituted])
        }
    }

    private struct Fixture {
        let privateKey: Curve25519.Signing.PrivateKey
        let trustRoot: CmxIrohRelayPolicyTrustRoot
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let relayURLs = [
            "https://usc1.relay.cmux.dev/",
            "https://euw4.relay.cmux.dev/",
        ]

        var nowSeconds: Int64 { Int64(now.timeIntervalSince1970) }

        init() throws {
            privateKey = Curve25519.Signing.PrivateKey()
            let key = try CmxIrohRelayPolicyVerificationKey(
                keyID: "policy-2026-1",
                rawPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
            trustRoot = try CmxIrohRelayPolicyTrustRoot(keys: [key])
        }

        func token(
            sequence: Int64,
            issuedAt: Int64? = nil,
            notBefore: Int64? = nil,
            expiresAt: Int64? = nil,
            relayProtocol: String = "iroh-relay-v1",
            keyID: String = "policy-2026-1",
            relayURLs: [String]? = nil,
            regions: [String]? = nil
        ) throws -> String {
            let header = try JSONSerialization.data(
                withJSONObject: [
                    "alg": "EdDSA",
                    "typ": "cmux-relay-policy-v1+jwt",
                    "kid": keyID,
                ],
                options: [.sortedKeys]
            )
            let payload = try payload(
                sequence: sequence,
                relayURLs: relayURLs,
                regions: regions,
                issuedAt: issuedAt,
                notBefore: notBefore,
                expiresAt: expiresAt,
                relayProtocol: relayProtocol
            )
            let signingInput = "\(Self.base64URL(header)).\(Self.base64URL(payload))"
            let signature = try privateKey.signature(for: Data(signingInput.utf8))
            return "\(signingInput).\(Self.base64URL(signature))"
        }

        func payload(
            sequence: Int64,
            relayURLs: [String]? = nil,
            regions: [String]? = nil,
            issuedAt: Int64? = nil,
            notBefore: Int64? = nil,
            expiresAt: Int64? = nil,
            relayProtocol: String = "iroh-relay-v1"
        ) throws -> Data {
            let urls = relayURLs ?? self.relayURLs
            let relayIDs = ["cmux-us", "cmux-eu"]
            let regions = regions ?? ["us-central1", "europe-west4"]
            let relays = urls.enumerated().map { index, url in
                [
                    "id": relayIDs[index],
                    "provider": "cmux",
                    "region": regions[index],
                    "url": url,
                ]
            }
            return try JSONSerialization.data(
                withJSONObject: [
                    "version": 1,
                    "jti": "123e4567-e89b-42d3-a456-426614174000",
                    "sequence": sequence,
                    "iat": issuedAt ?? nowSeconds,
                    "nbf": notBefore ?? issuedAt ?? nowSeconds,
                    "exp": expiresAt ?? nowSeconds + 3_600,
                    "aud": "cmux-iroh-relay-policy",
                    "relay_protocol": relayProtocol,
                    "relays": relays,
                ],
                options: [.sortedKeys]
            )
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        func relayConfiguration(url: String) throws -> CmxIrohRelayConfiguration {
            try CmxIrohRelayConfiguration(
                url: url,
                token: "aaaa",
                expiresAt: now.addingTimeInterval(3_600),
                refreshAfter: now.addingTimeInterval(1_800),
                now: now
            )
        }
    }
}
