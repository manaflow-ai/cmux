import CryptoKit
import Foundation
import Testing
@testable import CmuxInstallAuthCore

/// A software P-256 signer (tests only).
struct SoftwareSigner: InstallSigner {
    let key = P256.Signing.PrivateKey()
    let der: Bool
    func publicKeyX963() async throws -> Data { key.publicKey.x963Representation }
    func sign(_ message: Data) async throws -> Data {
        let signature = try key.signature(for: message)
        return der ? signature.derRepresentation : signature.rawRepresentation
    }
}

/// A fake owner that checks what the real routes check.
actor FakeOwner: InstallAuthTransport {
    var publicKey: P256.Signing.PublicKey?
    var issued: Set<String> = []
    var redeemed: Set<String> = []
    var mints = 0
    var sessionCalls = 0
    let prefix = "cmux-install-auth/v1/staging/inst_1/"

    nonisolated func post(_ path: String, json: Data, bearer: String?) async throws -> (status: Int, body: Data) {
        try await handle(path, json, bearer)
    }

    private func reply(_ object: [String: Any], _ status: Int = 200) throws -> (status: Int, body: Data) {
        (status, try JSONSerialization.data(withJSONObject: object))
    }

    private func handle(_ path: String, _ json: Data, _ bearer: String?) throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        switch path {
        case "/v1/ops":
            guard bearer == "session-token" else { return try reply(["code": "auth.unauthenticated"], 401) }
            sessionCalls += 1
            let params = body["params"] as! [String: Any]
            if body["op"] as? String == "user.ensure" { return try reply(["ok": true, "value": ["id": "user_1"]]) }
            let jwk = params["public_jwk"] as! [String: String]
            #expect(params["kind"] as? String == "ios")
            let x = Base64URL.decode(jwk["x"]!)!, y = Base64URL.decode(jwk["y"]!)!
            publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            return try reply(["ok": true, "value": ["id": "inst_1", "kind": "ios"]])
        case "/v1/auth/challenge":
            let nonce = UUID().uuidString
            issued.insert(nonce)
            return try reply(["nonce": nonce, "message_prefix": prefix, "expires_at": 0])
        case "/v1/auth/token":
            let nonce = body["nonce"] as! String
            guard issued.contains(nonce), !redeemed.contains(nonce),
                  let raw = Base64URL.decode(body["signature"] as! String), let key = publicKey else {
                return try reply(["code": "auth.forbidden"], 403)
            }
            redeemed.insert(nonce)
            let message = Data((prefix + nonce).utf8)
            let signature = raw.count == 64 ? try P256.Signing.ECDSASignature(rawRepresentation: raw)
                                            : try P256.Signing.ECDSASignature(derRepresentation: raw)
            guard key.isValidSignature(signature, for: message) else { return try reply(["code": "auth.forbidden"], 403) }
            mints += 1
            return try reply(["access_token": "install-token-\(mints)", "token_type": "Bearer",
                              "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000])
        default:
            return try reply([:], 404)
        }
    }
}

final class Clock: @unchecked Sendable {
    var now = Date()
}

@Suite struct InstallAuthClientTests {
    @Test(arguments: [false, true])
    func mintsATokenWithRawOrDERSignatures(der: Bool) async throws {
        let owner = FakeOwner()
        let client = InstallAuthClient(transport: owner, signer: SoftwareSigner(der: der),
                                       sessionToken: { "session-token" }, deviceName: "Aziz", record: nil)
        #expect(try await client.installToken() == "install-token-1")
        #expect(await client.currentRecord == InstallRecord(user: "user_1", install: "inst_1"))
    }

    @Test func tokenIsCachedThenRefreshedWithAFreshNonceAndNoSession() async throws {
        let owner = FakeOwner()
        let clock = Clock()
        let client = InstallAuthClient(transport: owner, signer: SoftwareSigner(der: false),
                                       sessionToken: { "session-token" }, deviceName: "Aziz", record: nil,
                                       now: { clock.now })
        _ = try await client.installToken()
        _ = try await client.installToken()
        #expect(await owner.mints == 1)
        clock.now = clock.now.addingTimeInterval(600 - InstallAuthClient.refreshMargin + 1)
        #expect(try await client.installToken() == "install-token-2")
        #expect(await owner.redeemed.count == 2)
        // Registration (the only session use) happened once.
        #expect(await owner.sessionCalls == 2)
    }

    @Test func aRefusedSignatureIsAnError() async {
        struct WrongSigner: InstallSigner {
            let shown = P256.Signing.PrivateKey(), used = P256.Signing.PrivateKey()
            func publicKeyX963() async throws -> Data { shown.publicKey.x963Representation }
            func sign(_ message: Data) async throws -> Data { try used.signature(for: message).rawRepresentation }
        }
        let client = InstallAuthClient(transport: FakeOwner(), signer: WrongSigner(),
                                       sessionToken: { "session-token" }, deviceName: "x", record: nil)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await client.installToken() }
    }

    @Test func base64URLHasNoPaddingAndRoundTrips() {
        let data = Data([0xFB, 0xFF, 0x00, 0x01])
        let text = Base64URL.encode(data)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(Base64URL.decode(text) == data)
        #expect(throws: InstallAuthError.invalidPublicKey) { try PublicJWK(x963: Data(count: 64)) }
    }
}
