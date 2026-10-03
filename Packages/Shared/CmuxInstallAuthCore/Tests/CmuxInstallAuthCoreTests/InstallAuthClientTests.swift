import CryptoKit
import Foundation
import Testing
@testable import CmuxInstallAuthCore

/// A software P-256 signer (tests only).
actor SoftwareSigner: InstallSigner {
    var key = P256.Signing.PrivateKey()
    let der: Bool
    var rotations = 0
    init(der: Bool = false) { self.der = der }
    func publicKeyX963() async throws -> Data { key.publicKey.x963Representation }
    func sign(_ message: Data) async throws -> Data {
        let signature = try key.signature(for: message)
        return der ? signature.derRepresentation : signature.rawRepresentation
    }
    func rotate() async throws { key = P256.Signing.PrivateKey(); rotations += 1 }
}

/// A fake owner that checks what the real routes check.
actor FakeOwner: InstallAuthTransport {
    var installs: [String: P256.Signing.PublicKey] = [:]   // install id -> key
    var revoked: Set<String> = []
    var ledger: [String: String] = [:]                      // register idempotency key -> install id
    var issued: Set<String> = []
    var redeemed: Set<String> = []
    var mints = 0
    var registerCalls = 0
    var failNextChallenge = false
    var prefixOverride: String?
    var grants: [[String]] = []

    func revoke(_ install: String) { revoked.insert(install) }
    func setFailNextChallenge() { failNextChallenge = true }
    func setPrefixOverride(_ value: String) { prefixOverride = value }

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
            if body["op"] as? String == "user.ensure" {
                return try reply(["ok": true, "value": ["id": "user_1", "stack_user_id": "stack_1"]])
            }
            if body["op"] as? String == "install.revoke" {
                let install = (body["params"] as! [String: Any])["install"] as! String
                revoked.insert(install)
                return try reply(["ok": true, "value": ["id": install]])
            }
            registerCalls += 1
            let key = body["idempotency_key"] as! String
            if let replay = ledger[key] { return try reply(["ok": true, "value": ["id": replay], "replayed": true]) }
            let params = body["params"] as! [String: Any]
            grants.append(params["op_classes"] as? [String] ?? [])
            let jwk = params["public_jwk"] as! [String: String]
            let x = Data(base64URLEncoded: jwk["x"]!)!, y = Data(base64URLEncoded: jwk["y"]!)!
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            if installs.values.contains(where: { $0.rawRepresentation == publicKey.rawRepresentation })
                && !installs.filter({ $0.value.rawRepresentation == publicKey.rawRepresentation }).keys.allSatisfy(revoked.contains) {
                return try reply(["ok": false, "error": ["code": "validation.invalid", "message": "this public key is already registered"]])
            }
            let id = "inst_\(installs.count + 1)"
            installs[id] = publicKey
            ledger[key] = id
            return try reply(["ok": true, "value": ["id": id, "kind": "ios"]])
        case "/v1/auth/challenge":
            let install = body["install"] as! String
            if failNextChallenge { failNextChallenge = false; return try reply(["code": "internal"], 500) }
            guard installs[install] != nil, !revoked.contains(install) else { return try reply(["code": "auth.forbidden"], 403) }
            let nonce = String(repeating: "0", count: 32) + String(issued.count)
            issued.insert(nonce)
            return try reply(["nonce": nonce, "message_prefix": prefixOverride ?? "cmux-auth-v1\nstaging\n\(install)\n", "expires_at": 0])
        case "/v1/auth/token":
            let nonce = body["nonce"] as! String, install = body["install"] as! String
            guard issued.contains(nonce), !redeemed.contains(nonce), let key = installs[install],
                  let raw = Data(base64URLEncoded: body["signature"] as! String) else { return try reply(["code": "auth.forbidden"], 403) }
            redeemed.insert(nonce)
            let message = Data("cmux-auth-v1\nstaging\n\(install)\n\(nonce)".utf8)
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

final class TestClock: @unchecked Sendable { var now = Date() }
actor RecordBox { var value: InstallRecord?; func set(_ v: InstallRecord?) { value = v } }

func makeClient(_ owner: FakeOwner, _ signer: SoftwareSigner, record: InstallRecord? = nil, session: Bool = true,
                box: RecordBox = RecordBox(), clock: TestClock = TestClock()) -> InstallAuthClient {
    InstallAuthClient(transport: owner, signer: signer, sessionToken: session ? { @Sendable in "session-token" } : nil,
                      stackUser: "stack_1", environment: "staging", deviceName: "Aziz", record: record,
                      onRecord: { await box.set($0) }, now: { clock.now })
}

@Suite struct InstallAuthClientTests {
    @Test(arguments: [false, true])
    func mintsATokenWithRawOrDERSignatures(der: Bool) async throws {
        let client = makeClient(FakeOwner(), SoftwareSigner(der: der))
        #expect(try await client.installToken() == "install-token-1")
        #expect(await client.currentRecord == InstallRecord(user: "user_1", install: "inst_1"))
    }

    @Test func tokenIsCachedThenRefreshedWithAFreshNonceWithoutASession() async throws {
        let owner = FakeOwner(), clock = TestClock()
        let first = makeClient(owner, SoftwareSigner(), clock: clock)
        _ = try await first.installToken()
        _ = try await first.installToken()
        #expect(await owner.mints == 1)
        clock.now = clock.now.addingTimeInterval(InstallAuthClient.maximumLifetime - InstallAuthClient.refreshMargin + 1)
        #expect(try await first.installToken() == "install-token-2")
        #expect(await owner.redeemed.count == 2)
    }

    @Test func theRecordIsSavedRightAfterRegisterAndALostRegisterReplays() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), box = RecordBox()
        await owner.setFailNextChallenge()
        let client = makeClient(owner, signer, box: box)
        await #expect(throws: InstallAuthError.refused("internal")) { try await client.installToken() }
        #expect(await box.value == InstallRecord(user: "user_1", install: "inst_1"))
        // A new client without the record (lost reply): the same key replays the same install.
        let again = makeClient(owner, signer)
        _ = try await again.installToken()
        #expect(await again.currentRecord?.install == "inst_1")
        #expect(await owner.installs.count == 1)
    }

    @Test func aRevokedInstallRegistersAgainWithANewKey() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), clock = TestClock()
        let client = makeClient(owner, signer, clock: clock)
        _ = try await client.installToken()
        await owner.revoke("inst_1")
        clock.now = clock.now.addingTimeInterval(3600)
        _ = try await client.installToken()
        #expect(await client.currentRecord?.install == "inst_2")
        #expect(await signer.rotations == 1)
    }

    @Test func withoutASessionARevokedInstallCannotRecover() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner()
        _ = try await makeClient(owner, signer).installToken()
        await owner.revoke("inst_1")
        let background = makeClient(owner, signer, record: InstallRecord(user: "user_1", install: "inst_1"), session: false)
        await #expect(throws: InstallAuthError.noSession) { try await background.installToken() }
    }

    @Test func aForeignChallengePrefixIsNeverSigned() async throws {
        let owner = FakeOwner()
        await owner.setPrefixOverride("anything the server wants\n")
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await makeClient(owner, SoftwareSigner()).installToken() }
    }

    @Test func thePhoneAsksForNoExecuteAndSignOutRevokes() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), box = RecordBox()
        let client = makeClient(owner, signer, box: box)
        _ = try await client.installToken()
        #expect(await owner.grants == [["read", "mutate-own", "mutate-shared"]])
        try await client.revoke()
        #expect(await owner.revoked == ["inst_1"])
        #expect(await client.currentRecord == nil)
        #expect(await box.value == nil)
        #expect(await signer.rotations == 1)
    }

    @Test func base64URLHasNoPaddingAndRoundTrips() {
        let data = Data([0xFB, 0xFF, 0x00, 0x01])
        let text = (data).base64URLEncoded
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(Data(base64URLEncoded: text) == data)
        #expect(throws: InstallAuthError.invalidPublicKey) { try PublicJWK(x963: Data(count: 64)) }
        #expect(InstallAuthClient.displayName("") == "iPhone")
        #expect(InstallAuthClient.displayName(String(repeating: "📱", count: 60)).utf16.count == 80)
    }
}
