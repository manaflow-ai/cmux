import CryptoKit
import Foundation
import Testing
@testable import CmuxTextConfirmCore

/// Records each POST and answers with a fixed status and body (or fails).
final class RecordingTransport: PresenceKeyTransport, @unchecked Sendable {
    struct Lost: Error {}
    var posts: [(path: String, body: [String: Any], bearer: String)] = []
    var failures = 0
    let status: Int
    let reply: Data

    init(status: Int = 200, reply: String = #"{"ok":true,"value":{}}"#) {
        self.status = status
        self.reply = Data(reply.utf8)
    }

    func post(_ path: String, json: Data, bearer: String) async throws -> (status: Int, body: Data) {
        posts.append((path, try JSONSerialization.jsonObject(with: json) as! [String: Any], bearer))
        if failures > 0 {
            failures -= 1
            throw Lost()
        }
        return (status, reply)
    }
}

/// A fake App Attest: the "attestation" is the client-data hash it was given.
final class FakeKeyAttester: AppAttestKeyAttester, @unchecked Sendable {
    var hashes: [Data] = []
    var generated = 0
    func generateKey() async throws -> String {
        generated += 1
        return "attest-key-\(generated)"
    }
    func attest(keyID: String, clientDataHash: Data) async throws -> Data {
        hashes.append(clientDataHash)
        return clientDataHash
    }
}

final class MemoryPendingStore: PendingAttestationStore, @unchecked Sendable {
    var value: PendingAttestation?
    func load() -> PendingAttestation? { value }
    func save(_ pending: PendingAttestation?) { value = pending }
}

@Suite struct PresenceKeyRegistrationTests {
    let installKey = P256.Signing.PrivateKey()
    let presenceKey = P256.Signing.PrivateKey()

    func install(der: Bool = false) -> PresenceKeyInstall {
        let key = installKey
        return PresenceKeyInstall(user: "user_1", install: "inst_1", environment: "staging",
                                  token: { "install-token" },
                                  sign: { message in
                                      let s = try key.signature(for: message)
                                      return der ? s.derRepresentation : s.rawRepresentation
                                  })
    }

    @Test func thumbprintIsRFC7638OverTheCanonicalMembers() throws {
        // Vector from Node: createHash("sha256").update(`{"crv":"P-256","kty":"EC","x":"<x>","y":"<y>"}`)
        // .digest("base64url"), the backend's jwkThumbprint, with x = bytes 1...32, y = bytes 33...64.
        let x963 = Data([0x04]) + Data(1...64)
        #expect(try PresenceKeyRegistration.thumbprint(x963: x963) == "t1ZI8tOt77KZ9YepYcUiqtqXcpIYInMJhkFb6casAFo")
        #expect(throws: PresenceKeyError.invalidPublicKey) { try PresenceKeyRegistration.thumbprint(x963: Data(1...64)) }
    }

    @Test func iOSSendsTheInstallSignatureAndAnAttestationOverTheThumbprint() async throws {
        let transport = RecordingTransport()
        let attester = FakeKeyAttester()
        let x963 = presenceKey.publicKey.x963Representation
        let result = try await PresenceKeyRegistration(transport: transport, attester: attester)
            .register(presenceKey: x963, platform: "ios", install: install(der: true))

        let thumbprint = try PresenceKeyRegistration.thumbprint(x963: x963)
        #expect(result == PresenceKeyRegistered(thumbprint: thumbprint, appAttestKeyID: "attest-key-1"))
        let post = try #require(transport.posts.first)
        #expect(transport.posts.count == 1)
        #expect(post.path == "/v1/presence-key")
        #expect(post.bearer == "install-token")
        #expect(post.body["platform"] as? String == "ios")
        #expect(post.body["jwk"] as? [String: String] == (try PresenceKeyRegistration.jwk(x963: x963)))
        #expect(post.body["key_id"] as? String == "attest-key-1")

        // The install key signed the exact line, sent raw r||s (DER converted).
        let message = Data("cmux-presence-key-v1\nstaging\nuser_1\ninst_1\n\(thumbprint)".utf8)
        let encoded = try #require(post.body["signature"] as? String)
        let signature = try #require(Data(textConfirmBase64URL: encoded))
        #expect(signature.count == 64)
        #expect(installKey.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))

        // clientDataHash = SHA-256 of the thumbprint's UTF-8 bytes.
        let hash = Data(SHA256.hash(data: Data(thumbprint.utf8)))
        #expect(attester.hashes == [hash])
        #expect(post.body["attestation"] as? String == hash.textConfirmBase64URL)
    }

    @Test func iOSWithoutAttesterRefusesBeforeAnyRequest() async {
        let transport = RecordingTransport()
        await #expect(throws: TextConfirmError.attestationUnavailable) {
            try await PresenceKeyRegistration(transport: transport, attester: nil)
                .register(presenceKey: presenceKey.publicKey.x963Representation, platform: "ios", install: install())
        }
        #expect(transport.posts.isEmpty)
    }

    @Test func macSendsNoAttestation() async throws {
        let transport = RecordingTransport()
        let result = try await PresenceKeyRegistration(transport: transport, attester: nil)
            .register(presenceKey: presenceKey.publicKey.x963Representation, platform: "mac", install: install())
        #expect(result.appAttestKeyID == nil)
        let body = try #require(transport.posts.first?.body)
        #expect(body["attestation"] == nil && body["key_id"] == nil)
    }

    @Test func ownerRefusalCarriesItsCode() async {
        let transport = RecordingTransport(
            status: 403, reply: #"{"ok":false,"error":{"code":"auth.forbidden","message":"attestation refused"}}"#)
        await #expect(throws: TextConfirmRefusal(code: "auth.forbidden")) {
            try await PresenceKeyRegistration(transport: transport, attester: FakeKeyAttester())
                .register(presenceKey: presenceKey.publicKey.x963Representation, platform: "ios", install: install())
        }
    }

    @Test func aLostAnswerResendsTheSameAttestationAndAnAnswerClearsIt() async throws {
        let transport = RecordingTransport()
        transport.failures = 1
        let attester = FakeKeyAttester()
        let store = MemoryPendingStore()
        let registration = PresenceKeyRegistration(transport: transport, attester: attester, pending: store)
        let x963 = presenceKey.publicKey.x963Representation

        await #expect(throws: RecordingTransport.Lost.self) {
            try await registration.register(presenceKey: x963, platform: "ios", install: install())
        }
        #expect(store.value?.keyID == "attest-key-1")
        let result = try await registration.register(presenceKey: x963, platform: "ios", install: install())
        #expect(attester.generated == 1)
        #expect(result.appAttestKeyID == "attest-key-1")
        #expect(transport.posts[0].body["attestation"] as? String == transport.posts[1].body["attestation"] as? String)
        #expect(store.value == nil)
    }

    @Test func aRefusalClearsThePendingAttestation() async {
        let transport = RecordingTransport(status: 403, reply: #"{"ok":false,"error":{"code":"auth.forbidden"}}"#)
        let store = MemoryPendingStore()
        await #expect(throws: TextConfirmRefusal(code: "auth.forbidden")) {
            try await PresenceKeyRegistration(transport: transport, attester: FakeKeyAttester(), pending: store)
                .register(presenceKey: presenceKey.publicKey.x963Representation, platform: "ios", install: install())
        }
        #expect(store.value == nil)
    }
}
