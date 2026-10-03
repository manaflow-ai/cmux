import CryptoKit
import Foundation
import Testing
@testable import CmuxTextConfirmCore

struct KeySigner: PresenceSigner {
    let key: P256.Signing.PrivateKey
    let der: Bool
    func sign(_ message: Data) async throws -> Data {
        let s = try key.signature(for: message)
        return der ? s.derRepresentation : s.rawRepresentation
    }
}

/// A broken client: re-encodes the challenge JSON before signing.
struct ReEncodingSigner: PresenceSigner {
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: message)
        let reencoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try key.signature(for: reencoded).rawRepresentation
    }
}

/// Echoes the client-data hash as the "assertion" so the test can read it.
struct EchoAttester: AppAttester {
    func assertion(clientDataHash: Data) async throws -> String { clientDataHash.textConfirmBase64URL }
}

final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

@Suite struct TextConfirmFlowTests {
    let key = P256.Signing.PrivateKey()

    func owner(_ clock: Clock, level: TextConfirmLevel = .strict) -> MockTextConfirmOwner {
        MockTextConfirmOwner(level: level, presenceKey: key.publicKey,
                             keyRegisteredAt: clock.now.addingTimeInterval(-25 * 3600), now: { clock.now })
    }

    @Test(arguments: [false, true])
    func loweringSignsTheExactBytesAsRaw64Base64URL(der: Bool) async throws {
        let clock = Clock(), owner = owner(clock)
        let flow = TextConfirmFlow(ops: owner, signer: KeySigner(key: key, der: der), attester: EchoAttester())
        #expect(try await flow.change(from: .strict, to: .off) == .lowered)
        #expect(await owner.level == .off)
    }

    @Test func reEncodingTheJSONFailsTheProof() async throws {
        let clock = Clock(), owner = owner(clock)
        let flow = TextConfirmFlow(ops: owner, signer: ReEncodingSigner(key: key), attester: nil)
        #expect(try await flow.change(from: .strict, to: .off) == .refused(code: "text_confirm.bad_signature"))
        #expect(await owner.level == .strict)
    }

    @Test func appAttestClientDataIsTheSHA256OfTheSameBytes() async throws {
        let clock = Clock(), owner = owner(clock)
        let challenge = try await owner.challenge(for: .off, idempotencyKey: "k")
        let raw = try TextConfirmFlow.rawSignature(try key.signature(for: challenge.message).rawRepresentation)
        let hash = Data(SHA256.hash(data: challenge.message))
        _ = try await owner.lower(to: .off, nonce: challenge.nonce, presenceSignature: raw.textConfirmBase64URL,
                                  appAttest: try await EchoAttester().assertion(clientDataHash: hash), idempotencyKey: "k2")
        #expect(await owner.lastAttestHash == hash)
    }

    @Test func aSaferLevelAppliesWithoutAProof() async throws {
        struct NoSigner: PresenceSigner { func sign(_ m: Data) async throws -> Data { Issue.record("signed"); return Data() } }
        let clock = Clock(), owner = owner(clock, level: .off)
        #expect(try await TextConfirmFlow(ops: owner, signer: NoSigner(), attester: nil).change(from: .off, to: .strict) == .lowered)
        #expect(await owner.level == .strict)
    }

    @Test func signaturesAreExactly64BytesAndBase64URL() throws {
        let der = try key.signature(for: Data("x".utf8)).derRepresentation
        let raw = try TextConfirmFlow.rawSignature(der)
        #expect(raw.count == 64)
        let text = raw.textConfirmBase64URL
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(throws: TextConfirmError.badSignature) { try TextConfirmFlow.rawSignature(Data([1, 2, 3])) }
    }

    @Test func aNonceIsSpentByAnyAttempt() async throws {
        let clock = Clock(), owner = owner(clock)
        let challenge = try await owner.challenge(for: .off, idempotencyKey: "k")
        #expect(try await owner.lower(to: .off, nonce: challenge.nonce, presenceSignature: "AA", appAttest: nil, idempotencyKey: "a") == .refused(code: "text_confirm.bad_signature"))
        let good = try key.signature(for: challenge.message).rawRepresentation.textConfirmBase64URL
        #expect(try await owner.lower(to: .off, nonce: challenge.nonce, presenceSignature: good, appAttest: nil, idempotencyKey: "b") == .refused(code: "text_confirm.nonce"))
    }

    @Test func aLockRemovesLevelsBelowItsMinimum() {
        let state = TextConfirmState(level: .strict, lockedBy: "Manaflow", lockedLevel: .destructiveOnly)
        #expect(state.selectable == [.strict, .destructiveOnly])
    }

    @Test func challengeBytesComeFromMessageNotFromSign() {
        let value: [String: Any] = ["sign": ["nonce": "n1", "new_level": "off"], "message": Data(#"{"b":1, "a":2}"#.utf8).textConfirmBase64URL]
        #expect(TextConfirmChallenge(value: value)?.message == Data(#"{"b":1, "a":2}"#.utf8))
        #expect(TextConfirmChallenge(value: ["sign": ["nonce": "n"], "message": ""]) == nil)
    }
}
