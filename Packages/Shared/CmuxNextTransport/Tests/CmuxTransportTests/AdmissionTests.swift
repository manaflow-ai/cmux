import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Admission (contract 3.x, 9.3)")
struct AdmissionTests {
    let signer = GrantSigner()
    let now: Int64 = 1_000_000

    private func mint(
        for identity: PeerIdentity, grantID: String = "g-1", expiresAt: Int64? = nil
    ) throws -> PairingGrant {
        try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: grantID, issuedAt: now, expiresAt: expiresAt)
    }

    @Test("A server-signed grant for the presenting device, ID, and app admits")
    func validGrantAdmits() throws {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: identity)
        let verifier = GrantVerifier(serverPublicKeyData: signer.publicKeyData)
        let decision = verifier.decide(
            grant: grant, presentedByKey: identity.publicKeyData,
            presentedByDeviceID: identity.deviceID, presentedByApp: identity.appIdentity,
            revokedGrantIDs: [], now: now)
        #expect(decision == .admit)
    }

    @Test("Every denial has its machine-readable code (3.2)")
    func denialCodes() throws {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let other = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let verifier = GrantVerifier(serverPublicKeyData: signer.publicKeyData)
        let grant = try mint(for: identity, expiresAt: now + 3600)

        func decide(
            _ grant: PairingGrant, key: Data? = nil, deviceID: String? = nil,
            app: String? = nil, revoked: Set<String> = [], at time: Int64? = nil
        ) -> AdmissionDecision {
            verifier.decide(
                grant: grant, presentedByKey: key ?? identity.publicKeyData,
                presentedByDeviceID: deviceID ?? identity.deviceID,
                presentedByApp: app ?? identity.appIdentity, revokedGrantIDs: revoked,
                now: time ?? now)
        }

        // Tampered signature.
        var tampered = grant
        tampered.signature = Data(repeating: 0, count: 64)
        #expect(decide(tampered) == .deny(.invalidSignature))

        // Tampered field invalidates the signature too (transcript covers it).
        var renamed = grant
        renamed.accountID = "acct-2"
        #expect(decide(renamed) == .deny(.invalidSignature))

        // The transcript also covers the device ID (1.5).
        var moved = grant
        moved.deviceID = "phone-2"
        #expect(decide(moved) == .deny(.invalidSignature))

        // Presented by a different network key than the grant binds.
        #expect(decide(grant, key: other.publicKeyData) == .deny(.keyMismatch))

        // Presented by a different device ID than the grant binds (1.5).
        #expect(decide(grant, deviceID: "phone-2") == .deny(.deviceIDMismatch))

        // Presented by a different app identity (contract 1.4).
        #expect(decide(grant, app: "dev.cmux.internal") == .deny(.appMismatch))

        // Revoked by grant ID.
        #expect(decide(grant, revoked: ["g-1"]) == .deny(.revoked))

        // Expired: enforced at admission time.
        #expect(decide(grant, at: now + 7200) == .deny(.expired))

        // No expiry field means no expiry enforcement (lifetime policy is D9).
        let evergreen = try mint(for: identity, grantID: "g-2")
        #expect(decide(evergreen, at: now + 10 * 365 * 86_400) == .admit)
    }

    @Test("A grant survives its wire encoding round-trip")
    func grantPayloadRoundTrip() throws {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: identity, expiresAt: now + 3600)
        let decoded = PairingGrant(payloadValue: grant.payloadValue)
        #expect(decoded == grant)
    }
}

extension AdmissionTests {
    @Test("The signing transcript is injective: shifted field boundaries change the bytes")
    func transcriptDomainSeparation() {
        func transcript(account: String, device: String) -> Data {
            PairingGrant.transcript(
                accountID: account, deviceID: device, devicePublicKey: Data([1, 2, 3]),
                appIdentity: "dev.cmux.lite", grantID: "g-1", issuedAt: 1, expiresAt: nil)
        }
        // v1 newline-joined free-form fields, so a separator INSIDE a field
        // moved the boundary: ("acct\nphone", "d") and ("acct", "phone\nd")
        // signed identically, and one signed grant verified as the other.
        #expect(
            transcript(account: "acct\nphone", device: "d")
                != transcript(account: "acct", device: "phone\nd"))
        // Field order/length is bound, not just content concatenation.
        #expect(
            transcript(account: "ab", device: "c") != transcript(account: "a", device: "bc"))
        // The domain prefix names the fixed encoding.
        #expect(transcript(account: "a", device: "b").starts(with: Data("cmux/peer/grant/v2".utf8)))
    }

    @Test("A grant minted for one field tuple never verifies as a shifted tuple")
    func shiftedTupleGrantDoesNotVerify() throws {
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "d")
        // Minted with a newline smuggled into the account field.
        let smuggled = try signer.mint(
            accountID: "acct-1\nphone-9", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: "g-s", issuedAt: now)
        // Re-interpreted with the boundary shifted into the device ID: the
        // signature must NOT carry over.
        var shifted = smuggled
        shifted.accountID = "acct-1"
        shifted.deviceID = "phone-9\n" + identity.deviceID
        let verifier = GrantVerifier(serverPublicKeyData: signer.publicKeyData)
        let decision = verifier.decide(
            grant: shifted, presentedByKey: identity.publicKeyData,
            presentedByDeviceID: shifted.deviceID, presentedByApp: identity.appIdentity,
            revokedGrantIDs: [], now: now)
        #expect(decision == .deny(.invalidSignature))
    }
}
