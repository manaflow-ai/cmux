import CmuxPairing
import CryptoKit
import Foundation
import Testing

@Suite struct LinkCertificateTests {
    let signer = SoftwareSigner()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var nowMillis: Int64 { 1_800_000_000_000 }

    func issuer(env: String = "test") -> LinkCertificateIssuer {
        LinkCertificateIssuer(environment: env, user: "user_a1", install: "inst_m1", signer: signer)
    }

    @Test func messageMatchesTheBackend() {
        let key = String(repeating: "A", count: 43)
        let message = LinkCertificate.signedMessage(environment: "test", purpose: .direct, user: "user_a", install: "inst_a", key: key, issuedAt: 1, expiresAt: 2)
        #expect(String(decoding: message, as: UTF8.self) == "cmux-link-cert/1\ntest\nuser_a\ninst_a\ndirect\n\(key)\n1\n2")
    }

    @Test func issuesAndVerifies() async throws {
        let x = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let cert = try await issuer().issue(purpose: .direct, key: x, now: now)
        #expect(cert.keyBytes == x)
        #expect(cert.expiresAt - cert.issuedAt == LinkPurpose.direct.maxLifetimeMilliseconds)
        try cert.verify(installKey: signer.key.publicKey, environment: "test", now: nowMillis)
        let json = try JSONEncoder().encode(cert)
        #expect(String(decoding: json, as: UTF8.self).contains("\"issued_at\""))
        #expect(try JSONDecoder().decode(LinkCertificate.self, from: json) == cert)
    }

    @Test(arguments: [0, 31, 33, 64])
    func rejectsInvalidKeyLength(_ length: Int) async {
        await #expect(throws: LinkCertificateError.badKey) {
            try await issuer().issue(purpose: .direct, key: Data(repeating: 0, count: length), now: now)
        }
    }

    @Test func refusesTamperWrongEnvironmentExpiryAndLifetime() async throws {
        let x = Data(repeating: 7, count: 32)
        let cert = try await issuer().issue(purpose: .direct, key: x, now: now)
        #expect(throws: LinkCertificateError.badSignature) { try cert.verify(installKey: signer.key.publicKey, environment: "production", now: nowMillis) }
        var tampered = cert
        tampered.key = Data(repeating: 8, count: 32).base64URLEncodedString()
        #expect(throws: LinkCertificateError.badSignature) { try tampered.verify(installKey: signer.key.publicKey, environment: "test", now: nowMillis) }
        #expect(throws: LinkCertificateError.badSignature) { try cert.verify(installKey: P256.Signing.PrivateKey().publicKey, environment: "test", now: nowMillis) }
        #expect(throws: LinkCertificateError.expired) { try cert.verify(installKey: signer.key.publicKey, environment: "test", now: cert.expiresAt) }
        var long = cert
        long.expiresAt = long.issuedAt + LinkPurpose.direct.maxLifetimeMilliseconds + 1
        #expect(throws: LinkCertificateError.lifetimeTooLong) { try long.verify(installKey: signer.key.publicKey, environment: "test", now: nowMillis) }
        let dtls = try await issuer().issue(purpose: .dtls, key: x, now: now, lifetime: 86_400_000)
        #expect(dtls.expiresAt - dtls.issuedAt == 15 * 60_000)
    }

    @Test func jwkRoundTrips() {
        let jwk = InstallPublicKey(signer.key.publicKey)
        #expect(jwk.x.count == 43 && jwk.y.count == 43)
        #expect(jwk.signingKey?.rawRepresentation == signer.key.publicKey.rawRepresentation)
        #expect(InstallPublicKey(x: "bad", y: "bad").signingKey == nil)
    }

    /// The same signature the backend test verifies (trust-domain.test.ts "Swift vector").
    @Test func crossLanguageVector() throws {
        let raw = Data((1...32).map { UInt8($0) })
        let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        let jwk = InstallPublicKey(key.publicKey)
        #expect(jwk.x == CrossLanguageVector.x)
        #expect(jwk.y == CrossLanguageVector.y)
        let cert = LinkCertificate(purpose: .direct, user: "user_a", install: "inst_a", key: String(repeating: "A", count: 43),
                                   issuedAt: 1_800_000_000_000, expiresAt: 1_800_086_400_000, signature: CrossLanguageVector.signature)
        try cert.verify(installKey: key.publicKey, environment: "test", now: 1_800_000_000_001)
    }
}
