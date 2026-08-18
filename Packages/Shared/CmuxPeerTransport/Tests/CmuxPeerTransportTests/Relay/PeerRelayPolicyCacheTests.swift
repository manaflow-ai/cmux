import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PeerRelayPolicyCacheTests {
    @Test func cacheRejectsPolicyRollbackAndReverifiesOnLoad() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        let sequenceSeven = try signer.token(sequence: 7)

        let installed = try await cache.install(
            signedPolicy: sequenceSeven,
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(installed.sequence == 7)

        let sequenceSix = try signer.token(sequence: 6)
        await #expect(throws: PeerRelayPolicyError.rollback) {
            try await cache.install(
                signedPolicy: sequenceSix,
                trustRoot: try signer.trustRoot(),
                now: signer.now
            )
        }

        let equivocatedSequenceSeven = try signer.token(
            sequence: 7,
            relayURLs: [
                signer.relayURLs[0],
                "https://alternate.relay.cmux.dev/",
            ]
        )
        await #expect(throws: PeerRelayPolicyError.rollback) {
            try await cache.install(
                signedPolicy: equivocatedSequenceSeven,
                trustRoot: try signer.trustRoot(),
                now: signer.now
            )
        }

        let restored = try await cache.load(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(restored?.sequence == 7)
    }

    @Test func cacheAcceptsRenewedEnvelopeForUnchangedCatalog() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        let renewalTime = signer.now.addingTimeInterval(120)
        let renewed = try signer.token(
            sequence: 7,
            issuedAt: signer.nowSeconds + 120,
            expiresAt: signer.nowSeconds + 3_720
        )
        let installed = try await cache.install(
            signedPolicy: renewed,
            trustRoot: try signer.trustRoot(),
            now: renewalTime
        )

        #expect(installed.sequence == 7)
        #expect(installed.issuedAt == signer.nowSeconds + 120)
        #expect(
            try await cache.load(trustRoot: try signer.trustRoot(), now: renewalTime)?
                .expiresAt == signer.nowSeconds + 3_720
        )
    }

    @Test func corruptPolicyCacheCannotEraseTheRollbackFloor() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        await store.replaceRecord(Data("corrupt".utf8))

        await #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try await cache.load(trustRoot: try signer.trustRoot(), now: signer.now)
        }
        await #expect(throws: PeerRelayPolicyError.invalidClaims) {
            try await cache.install(
                signedPolicy: signer.token(sequence: 6),
                trustRoot: try signer.trustRoot(),
                now: signer.now
            )
        }
        #expect(await store.currentData() == Data("corrupt".utf8))
    }

    @Test func resolveReturnsVerifiedPolicyWhileUnexpired() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution.policy?.sequence == 7)
        #expect(resolution.relays.map(\.url) == signer.relayURLs)
        #expect(!resolution.isDirectOnly)
    }

    @Test func resolveFailsClosedToDirectOnlyWhenNothingCached() async throws {
        let signer = PeerRelayPolicySigner()
        let cache = PeerRelayPolicyCache(store: InMemoryRelayPolicyStore())

        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution == .directOnly(.missing))
        #expect(resolution.relays.isEmpty)
    }

    @Test func resolveFailsClosedToDirectOnlyAtSignedExpiry() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7, expiresAt: signer.nowSeconds + 300),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        let beforeExpiry = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now.addingTimeInterval(299)
        )
        #expect(beforeExpiry.policy?.sequence == 7)

        let atExpiry = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now.addingTimeInterval(300)
        )
        #expect(atExpiry == .directOnly(.expired))
        #expect(atExpiry.relays.isEmpty)
    }

    @Test func resolveFailsClosedToDirectOnlyOnRollbackFloorViolation() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        let sequenceSeven = try signer.token(sequence: 7)
        _ = try await cache.install(
            signedPolicy: sequenceSeven,
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        // A tampered record claiming a higher floor than its own signed policy
        // contradicts the monotonic sequence and must fail closed.
        let catalog = zip(zip(signer.relayIDs, signer.regions), signer.relayURLs)
            .map { pair, url in
                [
                    "id": pair.0,
                    "provider": "cmux",
                    "region": pair.1,
                    "url": url,
                ]
            }
        let tamperedRecord = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "highestSequence": 8,
            "signedPolicy": sequenceSeven,
            "catalog": catalog,
            "issuedAt": signer.nowSeconds,
            "expiresAt": signer.nowSeconds + 3_600,
        ])
        await store.replaceRecord(tamperedRecord)

        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution == .directOnly(.rollback))
        #expect(resolution.relays.isEmpty)
    }

    @Test func resolveFailsClosedToDirectOnlyOnTamperedSignature() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        let stored = try #require(await store.currentData())
        var record = try #require(
            try JSONSerialization.jsonObject(with: stored) as? [String: Any]
        )
        let token = try #require(record["signedPolicy"] as? String)
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        let substitutedPayload = try signer.payload(
            sequence: 7,
            relayURLs: [signer.relayURLs[0], "https://capture.example.com/"]
        )
        record["signedPolicy"] = [
            String(segments[0]),
            PeerRelayPolicySigner.base64URL(substitutedPayload),
            String(segments[2]),
        ].joined(separator: ".")
        await store.replaceRecord(
            try JSONSerialization.data(withJSONObject: record)
        )

        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution == .directOnly(.invalid))
        #expect(resolution.relays.isEmpty)
    }

    @Test func resolveFailsClosedToDirectOnlyOnStorageFailure() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        await store.setFailReads(true)

        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution == .directOnly(.invalid))
        #expect(resolution.relays.isEmpty)
    }

    @Test func deactivateRemovesCachedRecord() async throws {
        let signer = PeerRelayPolicySigner()
        let store = InMemoryRelayPolicyStore()
        let cache = PeerRelayPolicyCache(store: store)
        _ = try await cache.install(
            signedPolicy: signer.token(sequence: 7),
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )

        try await cache.deactivate()
        #expect(await store.currentData() == nil)
        let resolution = await cache.resolve(
            trustRoot: try signer.trustRoot(),
            now: signer.now
        )
        #expect(resolution == .directOnly(.missing))
    }
}
