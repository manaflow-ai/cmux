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

/// A broken client: re-encodes the JSON after the domain line before signing.
struct ReEncodingSigner: PresenceSigner {
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) async throws -> Data {
        let prefix = Data((TextConfirmChallenge.domain + "\n").utf8)
        let object = try JSONSerialization.jsonObject(with: message.dropFirst(prefix.count))
        let reencoded = prefix + (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return try key.signature(for: reencoded).rawRepresentation
    }
}

/// Echoes the client-data hash as the "assertion" (the mock checks it).
struct EchoAttester: AppAttester {
    func assertion(clientDataHash: Data) async throws -> String { clientDataHash.textConfirmBase64URL }
}

final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

@Suite struct TextConfirmFlowTests {
    let key = P256.Signing.PrivateKey()

    func owner(_ clock: TestClock, level: TextConfirmLevel = .strict, locked: TextConfirmLevel? = nil,
               registeredHoursAgo: Double = 25, nonCanonical: Bool = false) -> MockTextConfirmOwner {
        MockTextConfirmOwner(level: level, lockedLevel: locked, presenceKey: key.publicKey,
                             keyRegisteredAt: clock.now.addingTimeInterval(-registeredHoursAgo * 3600),
                             nonCanonical: nonCanonical, now: { clock.now })
    }

    func flow(_ owner: MockTextConfirmOwner, signer: (any PresenceSigner)? = nil) -> TextConfirmFlow {
        TextConfirmFlow(ops: owner, signer: signer ?? KeySigner(key: key, der: false), attester: EchoAttester(),
                        requiresAttestation: true)
    }

    @Test(arguments: [false, true])
    func loweringSignsTheExactBytesAsRaw64AndAttestsTheirHash(der: Bool) async throws {
        let owner = owner(TestClock())
        #expect(try await flow(owner, signer: KeySigner(key: key, der: der)).change(from: .strict, to: .off) == .lowered)
        #expect(await owner.level == .off)
        #expect(await owner.lastAttestHash?.count == 32)
    }

    @Test func reEncodingTheJSONFailsTheProof() async throws {
        let owner = owner(TestClock(), nonCanonical: true)
        #expect(try await flow(owner, signer: ReEncodingSigner(key: key)).change(from: .strict, to: .off)
                == .refused(code: "text_confirm.bad_proof"))
        #expect(await owner.level == .strict)
        // The same non-canonical bytes signed as they are pass.
        #expect(try await flow(owner).change(from: .strict, to: .off) == .lowered)
    }

    @Test func iOSNeedsAnAttesterBeforeAnythingIsSigned() async {
        let flow = TextConfirmFlow(ops: owner(TestClock()), signer: KeySigner(key: key, der: false), attester: nil,
                                   requiresAttestation: true)
        await #expect(throws: TextConfirmError.attestationUnavailable) { try await flow.change(from: .strict, to: .off) }
    }

    @Test func aSaferLevelAppliesWithoutAProof() async throws {
        struct NoSigner: PresenceSigner { func sign(_ m: Data) async throws -> Data { Issue.record("signed"); return Data() } }
        let owner = owner(TestClock(), level: .off)
        #expect(try await flow(owner, signer: NoSigner()).change(from: .off, to: .strict) == .lowered)
        #expect(await owner.level == .strict)
    }

    @Test func ownerRefusalsAreTyped() async throws {
        await #expect(throws: TextConfirmRefusal(code: "text_confirm.key_cooling_down")) {
            try await flow(owner(TestClock(), registeredHoursAgo: 1)).change(from: .strict, to: .off)
        }
        await #expect(throws: TextConfirmRefusal(code: "text_confirm.locked")) {
            try await flow(owner(TestClock(), locked: .destructiveOnly)).change(from: .strict, to: .off)
        }
    }

    @Test func theClientNeverSignsAForeignMessage() async throws {
        struct Foreign: TextConfirmOps {
            func state() async throws -> TextConfirmState { TextConfirmState() }
            func setLevel(_ level: TextConfirmLevel, idempotencyKey: String) async throws {}
            func challenge(for level: TextConfirmLevel, idempotencyKey: String) async throws -> TextConfirmChallenge {
                TextConfirmChallenge(nonce: "n", message: Data("transfer $1000 to mallory".utf8))
            }
            func lower(to level: TextConfirmLevel, nonce: String, presenceSignature: String, appAttest: String?,
                       idempotencyKey: String) async throws -> TextConfirmOutcome { .lowered }
        }
        struct NoSigner: PresenceSigner { func sign(_ m: Data) async throws -> Data { Issue.record("signed"); return Data() } }
        let flow = TextConfirmFlow(ops: Foreign(), signer: NoSigner(), attester: EchoAttester(), requiresAttestation: true)
        await #expect(throws: TextConfirmError.badChallenge) { try await flow.change(from: .strict, to: .off) }
    }

    @Test func aNonceIsSpentAndExpiryIsExclusive() async throws {
        let clock = TestClock(), owner = owner(clock)
        let challenge = try await owner.challenge(for: .off, idempotencyKey: "k")
        #expect(try await owner.lower(to: .off, nonce: challenge.nonce, presenceSignature: "AA", appAttest: nil, idempotencyKey: "a")
                == .refused(code: "text_confirm.bad_proof"))
        await #expect(throws: TextConfirmRefusal(code: "text_confirm.bad_nonce")) {
            try await owner.lower(to: .off, nonce: challenge.nonce, presenceSignature: "AA", appAttest: nil, idempotencyKey: "b")
        }
        let second = try await owner.challenge(for: .off, idempotencyKey: "k2")
        clock.now = clock.now.addingTimeInterval(120)
        #expect(try await owner.lower(to: .off, nonce: second.nonce, presenceSignature: "AA", appAttest: nil, idempotencyKey: "c")
                == .refused(code: "text_confirm.proof_expired"))
    }

    @Test func signaturesAreExactly64BytesAndBase64URL() throws {
        let raw = try TextConfirmFlow.rawSignature(try key.signature(for: Data("x".utf8)).derRepresentation)
        #expect(raw.count == 64)
        let text = raw.textConfirmBase64URL
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(throws: TextConfirmError.badSignature) { try TextConfirmFlow.rawSignature(Data([1, 2, 3])) }
    }

    @Test func aLockRemovesLevelsBelowItsMinimum() {
        let state = TextConfirmState(level: .strict, lockedBy: "Manaflow", lockedLevel: .destructiveOnly)
        #expect(state.selectable == [.strict, .destructiveOnly])
    }

    @Test func challengeBytesComeFromMessageAndMustNameTheLevel() {
        let bytes = Data("cmux-text-confirm-v1\n{\"b\":1, \"a\":2}".utf8)
        let value: [String: Any] = ["sign": ["nonce": "n1", "new_level": "off"], "message": bytes.textConfirmBase64URL]
        #expect(TextConfirmChallenge(value: value, level: .off)?.message == bytes)
        #expect(TextConfirmChallenge(value: value, level: .destructiveOnly) == nil)
    }
}
