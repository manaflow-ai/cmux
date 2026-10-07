import CmuxControlPlane
import CmuxLinkDirect
import CmuxMobileWire
import CmuxPairing
import Foundation
import Testing

@Suite struct TrustStoreTests {
    let f = TrustFixtures()

    @Test func appliesOwnerEventsLikeTheBackend() async throws {
        var state = try await f.populated()
        #expect(state.devices["inst_m1"]?.host == "host_a1")
        #expect(state.devices["inst_p1"]?.certs.direct?.keyBytes == f.phoneKey)
        #expect(state.guests["host_a1/inst_g1"]?.device.user == "user_b1")
        #expect(state.remote["host_b1/inst_p1"]?.hostInstall == "inst_bm")
        // Rotation replaces the cert; the host binding stays.
        let rotated = try await f.cert(f.mac, user: "user_a1", install: "inst_m1", key: f.phoneKey)
        try state.apply(try f.keySet(f.mac, install: "inst_m1", kind: "mac", name: "Studio", host: nil, cert: rotated, seq: 5))
        #expect(state.devices["inst_m1"]?.certs.direct == rotated)
        #expect(state.devices["inst_m1"]?.host == "host_a1")
        // Install revocation drops its keys and its acceptances.
        try state.apply(f.event("trust.install.revoked", .object(["install": .string("inst_p1")]), seq: 6))
        #expect(state.devices["inst_p1"] == nil)
        #expect(state.remote.isEmpty)
        try state.apply(f.event("trust.guest.remove", .object(["host": .string("host_a1"), "install": .string("inst_g1")]), seq: 7))
        #expect(state.guests.isEmpty)
        #expect(throws: TrustStoreEventError.self) { try state.apply(f.event("trust.request.remove", .object([:]), seq: 8)) }
    }

    @Test func snapshotRoundTripsAndRequestsExpire() async throws {
        var state = try await f.populated()
        var request = try f.peer(f.guestPhone, install: "inst_g2", user: "user_b1", cert: try await f.cert(f.guestPhone, user: "user_b1", install: "inst_g2", key: f.guestKey))
        request["offer_id"] = .string(String(repeating: "q", count: 43))
        request["host"] = .string("host_a1")
        request["host_name"] = .string("Studio")
        request["team"] = .string("team_a1")
        request["expires_at"] = .int(TrustFixtures.nowMillis + 100)
        try state.apply(f.event("trust.request.add", .object(request), seq: 10))
        #expect(state.requests.count == 1)
        let json = try JSONValue(encoding: state)
        #expect(try TrustStoreState(snapshot: json) == state)
        // A later event at or past the expiry drops it, as the owner does on its next write.
        try state.apply(f.event("trust.unknown", .object([:]), seq: 200))
        #expect(state.requests.isEmpty)
    }

    @Test func lookupAnswersFromVerifiedCertsOnly() async throws {
        var state = try await f.populated()
        let mirror = TrustStoreMirror(state: state)
        let lookup = TrustStoreKeyLookup(mirror: mirror, environment: TrustFixtures.env, user: "user_a1", now: { TrustFixtures.now })
        let own = try #require(await lookup.hostKey(for: "host_a1"))
        #expect(own.directKey == f.macKey && own.isOwnAccount && own.install == "inst_m1")
        let remote = try #require(await lookup.hostKey(for: "host_b1"))
        #expect(remote.directKey == f.otherMacKey && !remote.isOwnAccount && remote.ownerUser == "user_b1")
        #expect(await lookup.hostKey(for: "host_zz") == nil)
        #expect(await lookup.isTrustedDevice(directKey: f.phoneKey, onHost: nil))
        #expect(await lookup.isTrustedDevice(directKey: f.guestKey, onHost: "host_a1"))
        #expect(!(await lookup.isTrustedDevice(directKey: f.guestKey, onHost: "host_other")))
        #expect(!(await lookup.isTrustedDevice(directKey: f.guestKey, onHost: nil)))
        // B4's authorizer hook.
        let authorizer = TrustStoreAuthorizer(lookup: lookup, host: "host_a1")
        #expect(await authorizer.authorize(device: try #require(DirectPublicKey(rawRepresentation: f.guestKey))))
        #expect(!(await authorizer.authorize(device: try #require(DirectPublicKey(rawRepresentation: Data(repeating: 1, count: 32))))))
        // A cert the owner swapped in for another install key fails verification.
        state.devices["inst_m1"]?.publicKey = f.otherMac.publicKey
        let forged = TrustStoreKeyLookup(mirror: TrustStoreMirror(state: state), environment: TrustFixtures.env, user: "user_a1", now: { TrustFixtures.now })
        #expect(await forged.hostKey(for: "host_a1") == nil)
        // Another environment's certs never count.
        let staging = TrustStoreKeyLookup(mirror: mirror, environment: "staging", user: "user_a1", now: { TrustFixtures.now })
        #expect(!(await staging.isTrustedDevice(directKey: f.phoneKey, onHost: nil)))
    }

    @Test func verifiesDTLSFingerprintProofs() async throws {
        let state = try await f.populated()
        let lookup = TrustStoreKeyLookup(mirror: TrustStoreMirror(state: state), environment: TrustFixtures.env, user: "user_a1", now: { TrustFixtures.now })
        let fingerprint = Data(repeating: 9, count: 32)
        let fromMac = try await f.cert(f.mac, user: "user_a1", install: "inst_m1", key: fingerprint, purpose: .dtls)
        #expect(await lookup.verifyFingerprint(fromMac, from: "inst_m1"))
        #expect(!(await lookup.verifyFingerprint(fromMac, from: "inst_p1")))
        let fromRemote = try await f.cert(f.otherMac, user: "user_b1", install: "inst_bm", key: fingerprint, purpose: .dtls)
        #expect(await lookup.verifyFingerprint(fromRemote, from: "inst_bm"))
        let direct = try await f.cert(f.mac, user: "user_a1", install: "inst_m1", key: fingerprint)
        #expect(!(await lookup.verifyFingerprint(direct, from: "inst_m1")))
    }

    @Test func mirrorAppliesSnapshotsAndEventsAndAsksForResync() async throws {
        let mirror = TrustStoreMirror()
        var updates = await mirror.updates().makeAsyncIterator()
        #expect(!(await mirror.apply(.event(f.event("trust.request.remove", .object(["offer_id": .string("x")]), seq: 1)))))
        let snapshot = SnapshotFrame(stream: "trust:user_a1", seq: 4, state: try JSONValue(encoding: try await f.populated()), decided: [])
        #expect(await mirror.apply(.snapshot(snapshot)))
        #expect(await updates.next()?.devices.count == 2)
        #expect(await mirror.apply(.event(f.event("trust.install.revoked", .object(["install": .string("inst_m1")]), seq: 5))))
        #expect(await updates.next()?.devices.count == 1)
        #expect(!(await mirror.apply(.event(f.event("trust.key.set", .object([:]), seq: 6)))))
    }
}
