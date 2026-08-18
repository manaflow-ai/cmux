import CryptoKit
import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PeerRelayPolicyVerifierTests {
    @Test func verifiesGenuinePolicyAndCatalog() throws {
        let signer = PeerRelayPolicySigner()
        let policy = try PeerRelayPolicyVerifier().verify(
            signer.token(sequence: 7),
            trustRoot: signer.trustRoot(),
            now: signer.now
        )

        #expect(policy.sequence == 7)
        #expect(policy.policyID == "123e4567-e89b-42d3-a456-426614174000")
        #expect(policy.relayProtocol == "iroh-relay-v1")
        #expect(policy.relays.map(\.url) == signer.relayURLs)
        #expect(policy.relays.map(\.id) == signer.relayIDs)
    }

    @Test func appPinnedTrustRootAcceptsCurrentAndStagedNextKeys() throws {
        let current = Curve25519.Signing.PrivateKey()
        let next = Curve25519.Signing.PrivateKey()
        let trustRoot = PeerRelayPolicyTrustRoot.appPinned(infoDictionary: [
            "CMUXIrohRelayPolicyTrustKeys": [
                [
                    "keyID": "policy-current",
                    "publicKeyBase64": current.publicKey.rawRepresentation
                        .base64EncodedString(),
                ],
                [
                    "keyID": "policy-next",
                    "publicKeyBase64": next.publicKey.rawRepresentation
                        .base64EncodedString(),
                ],
            ],
        ])

        #expect(trustRoot?.keys.map(\.keyID) == ["policy-current", "policy-next"])
    }

    @Test func appPinnedTrustRootFailsClosedForPartialRotationConfiguration() throws {
        let current = Curve25519.Signing.PrivateKey()
        let trustRoot = PeerRelayPolicyTrustRoot.appPinned(infoDictionary: [
            "CMUXIrohRelayPolicyTrustKeys": [
                [
                    "keyID": "policy-current",
                    "publicKeyBase64": current.publicKey.rawRepresentation
                        .base64EncodedString(),
                ],
                ["keyID": "policy-next"],
            ],
            "CMUXIrohRelayPolicyKeyID": "policy-current",
            "CMUXIrohRelayPolicyPublicKeyBase64": current.publicKey.rawRepresentation
                .base64EncodedString(),
        ])

        #expect(trustRoot == nil)
    }

    @Test func tamperedPayloadFailsSignature() throws {
        let signer = PeerRelayPolicySigner()
        let valid = try signer.token(sequence: 7)
        let segments = valid.split(separator: ".", omittingEmptySubsequences: false)
        let substitutedPayload = try signer.payload(
            sequence: 7,
            relayURLs: [
                signer.relayURLs[0],
                "https://capture.example.com/",
            ]
        )
        let substituted = [
            String(segments[0]),
            PeerRelayPolicySigner.base64URL(substitutedPayload),
            String(segments[2]),
        ].joined(separator: ".")

        #expect(throws: PeerRelayPolicyError.invalidSignature) {
            try PeerRelayPolicyVerifier().verify(
                substituted,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func wrongSigningKeyFailsSignature() throws {
        let signer = PeerRelayPolicySigner()
        let impostor = Curve25519.Signing.PrivateKey()
        let forged = try signer.token(sequence: 7, signingKey: impostor)

        #expect(throws: PeerRelayPolicyError.invalidSignature) {
            try PeerRelayPolicyVerifier().verify(
                forged,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func unknownKeyIDRejected() throws {
        let signer = PeerRelayPolicySigner()
        let unknownKey = try signer.token(sequence: 3, headerKeyID: "future-key")

        #expect(throws: PeerRelayPolicyError.unknownKeyID) {
            try PeerRelayPolicyVerifier().verify(
                unknownKey,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func expiredPolicyRejected() throws {
        let signer = PeerRelayPolicySigner()
        let expired = try signer.token(
            sequence: 1,
            expiresAt: signer.nowSeconds + 60
        )

        #expect(throws: PeerRelayPolicyError.expired) {
            try PeerRelayPolicyVerifier().verify(
                expired,
                trustRoot: signer.trustRoot(),
                now: signer.now.addingTimeInterval(60)
            )
        }
    }

    @Test func notBeforeSkewBoundedAtThirtySeconds() throws {
        let signer = PeerRelayPolicySigner()
        let tolerated = try signer.token(
            sequence: 4,
            notBefore: signer.nowSeconds + 30
        )

        #expect(throws: Never.self) {
            try PeerRelayPolicyVerifier().verify(
                tolerated,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }

        let excessive = try signer.token(
            sequence: 5,
            notBefore: signer.nowSeconds + 31
        )
        #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try PeerRelayPolicyVerifier().verify(
                excessive,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func unsupportedRelayProtocolRejected() throws {
        let signer = PeerRelayPolicySigner()
        let unsupported = try signer.token(
            sequence: 2,
            relayProtocol: "iroh-relay-v2"
        )

        #expect(throws: PeerRelayPolicyError.unsupportedRelayProtocol) {
            try PeerRelayPolicyVerifier().verify(
                unsupported,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func nonPositiveSequenceRejected() throws {
        let signer = PeerRelayPolicySigner()
        let zero = try signer.token(sequence: 0)

        #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try PeerRelayPolicyVerifier().verify(
                zero,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func relayCountBoundedAtSixteen() throws {
        let signer = PeerRelayPolicySigner()
        let seventeen = (0 ..< 17).map { index in
            [
                "id": "relay-\(index)",
                "provider": "cmux",
                "region": "region-\(index)",
                "url": "https://r\(index).relay.cmux.dev/",
            ]
        }
        let oversized = try signer.token(sequence: 6, relaysOverride: seventeen)

        #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try PeerRelayPolicyVerifier().verify(
                oversized,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }

        let sixteen = Array(seventeen.prefix(16))
        let bounded = try signer.token(sequence: 6, relaysOverride: sixteen)
        let policy = try PeerRelayPolicyVerifier().verify(
            bounded,
            trustRoot: signer.trustRoot(),
            now: signer.now
        )
        #expect(policy.relays.count == 16)
    }

    @Test func duplicateRelayURLsRejected() throws {
        let signer = PeerRelayPolicySigner()
        let duplicated = try signer.token(
            sequence: 6,
            relayURLs: [signer.relayURLs[0], signer.relayURLs[0]]
        )

        #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try PeerRelayPolicyVerifier().verify(
                duplicated,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func nonCanonicalRelayURLRejected() throws {
        let signer = PeerRelayPolicySigner()
        for url in [
            "http://usc1.relay.cmux.dev/",
            "https://usc1.relay.cmux.dev/?admin=1",
            "https://USC1.relay.cmux.dev/",
            "https://user:pw@usc1.relay.cmux.dev/",
        ] {
            let malformed = try signer.token(
                sequence: 6,
                relayURLs: [url, signer.relayURLs[1]]
            )
            #expect(throws: PeerRelayPolicyError.invalidClaims) {
                try PeerRelayPolicyVerifier().verify(
                    malformed,
                    trustRoot: signer.trustRoot(),
                    now: signer.now
                )
            }
        }
    }

    @Test func extraClaimKeyRejected() throws {
        let signer = PeerRelayPolicySigner()
        let widened = try signer.token(
            sequence: 6,
            extraClaims: ["scope": "everything"]
        )

        #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try PeerRelayPolicyVerifier().verify(
                widened,
                trustRoot: signer.trustRoot(),
                now: signer.now
            )
        }
    }

    @Test func explicitHTTPSPortAndDisplayLabelsAccepted() throws {
        let signer = PeerRelayPolicySigner()
        let token = try signer.token(
            sequence: 8,
            relayURLs: [
                "https://usc1.relay.cmux.dev:8443/",
                signer.relayURLs[1],
            ],
            regions: ["US Central", "Europe West"]
        )

        let policy = try PeerRelayPolicyVerifier().verify(
            token,
            trustRoot: signer.trustRoot(),
            now: signer.now
        )
        #expect(policy.relays.map(\.region) == ["US Central", "Europe West"])
        #expect(policy.relays[0].url == "https://usc1.relay.cmux.dev:8443/")
    }
}
