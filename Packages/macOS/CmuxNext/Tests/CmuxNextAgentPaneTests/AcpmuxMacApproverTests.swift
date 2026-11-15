import CryptoKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Peer-route approvals: this Mac's approver key signs the bytes acpmux checks
/// (`hub/mac_approvers.rs`), and the signature verifies with the public key it enrolls.
@Suite struct AcpmuxMacApproverTests {
    /// The same vector as acpmux's `the_wire_payload_is_fixed` (hub/mac_approvers_tests.rs).
    @Test func theSignedBytesMatchAcpmuxsVector() {
        let message = AcpmuxMacApprover.message(instance: "0123abcd", mac: "mac-9f1c2d3e4f5a6b7c", session: "sess-1",
                                                permission: "perm-7", toolCall: "toolu_01", option: "allow_once",
                                                nonce: String(repeating: "ab", count: 32), expiresAt: 1_760_000_000, answers: "")
        #expect(message.starts(with: Data("acpmux-mac-approver-decision-v1\u{0}".utf8)))
        let digest = SHA256.hash(data: message).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "e78a2bf7ed824fa614115c1c2fdc73b913c3486d1213b74e73b57c6bafcec4a0")
    }

    @Test func aDecisionVerifiesWithTheEnrolledKeyAndCoversItsAnswers() async throws {
        let approver = AcpmuxMacApprover()
        let identity = try #require(approver.identity)
        #expect(identity.id.hasPrefix("mac-") && identity.id.count == 20)
        #expect(identity.publicKey.count == 130 && identity.publicKey.hasPrefix("04"))
        let now = Date(timeIntervalSince1970: 1_000)
        let answers = try #require(AcpmuxSecretKey.canonicalDigest(["Which?": "A"]))
        let decision = try #require(await approver.decision(instance: "i", session: "s", permission: "p", toolCall: "c", option: "yes",
                                                            nonce: "n", answers: answers, now: now))
        #expect(decision["approver"] as? String == identity.id)
        let expires = try #require(decision["expiresAt"] as? UInt64)
        #expect(expires == 1_120)
        let key = try P256.Signing.PublicKey(x963Representation: Self.bytes(identity.publicKey))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.bytes(try #require(decision["signature"] as? String)))
        func signed(_ toolCall: String, _ answers: String) -> Data {
            AcpmuxMacApprover.message(instance: "i", mac: identity.id, session: "s", permission: "p", toolCall: toolCall,
                                      option: "yes", nonce: "n", expiresAt: expires, answers: answers)
        }
        #expect(key.isValidSignature(signature, for: signed("c", answers)))
        #expect(!key.isValidSignature(signature, for: signed("other", answers)))
        #expect(!key.isValidSignature(signature, for: signed("c", "")))
    }

    /// The consent grant contract's test vector (acpmux `consent_grant::message` has the same one).
    @Test func theConsentGrantBytesMatchTheContractVector() {
        let message = AcpmuxMacApprover.consentGrantMessage(grantor: "mac-0011223344556677", account: "user_abc", machineId: "m_1",
                                                            nodeKey: "AAAA", control: "on", screen: "keep", issuedAt: 1000, expiresAt: 2000)
        #expect(message == Data("acpmux-consent-grant-v1\u{0}mac-0011223344556677\u{0}user_abc\u{0}m_1\u{0}AAAA\u{0}on\u{0}keep\u{0}1000\u{0}2000".utf8))
        let hex = message.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "6163706d75782d636f6e73656e742d6772616e742d7631006d61632d30303131323233333434353536363737"
            + "00757365725f616263006d5f310041414141006f6e006b65657000313030300032303030")
    }

    /// A signed grant names this Mac's key, lives 120 s from `now` in milliseconds, carries the public key
    /// and name for the target's ask, and verifies under that key only for the bytes it names.
    @Test func aConsentGrantVerifiesWithThisMacsKey() async throws {
        let approver = AcpmuxMacApprover()
        let identity = try #require(approver.identity)
        let now = Date(timeIntervalSince1970: 1_794_781_755.5)
        let grant = try #require(await approver.consentGrant(account: "user_abc", machineId: "m_1", nodeKey: "AAAA",
                                                             control: .on, screen: .on, name: "Studio", now: now))
        #expect(grant["v"] as? Int == 1)
        #expect(grant["grantor"] as? String == identity.id)
        #expect(grant["publicKey"] as? String == identity.publicKey)
        #expect(grant["name"] as? String == "Studio")
        #expect(grant["control"] as? String == "on" && grant["screen"] as? String == "on")
        let issuedAt = try #require(grant["issuedAt"] as? UInt64)
        let expiresAt = try #require(grant["expiresAt"] as? UInt64)
        #expect(issuedAt == 1_794_781_755_500)
        #expect(expiresAt == issuedAt + 120_000)
        let key = try P256.Signing.PublicKey(x963Representation: Self.bytes(identity.publicKey))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.bytes(try #require(grant["signature"] as? String)))
        func signed(_ control: String, account: String = "user_abc", nodeKey: String = "AAAA") -> Data {
            AcpmuxMacApprover.consentGrantMessage(grantor: identity.id, account: account, machineId: "m_1", nodeKey: nodeKey,
                                                  control: control, screen: "on", issuedAt: issuedAt, expiresAt: expiresAt)
        }
        #expect(key.isValidSignature(signature, for: signed("on")))
        #expect(!key.isValidSignature(signature, for: signed("off")))
        #expect(!key.isValidSignature(signature, for: signed("on", account: "user_other")))
        #expect(!key.isValidSignature(signature, for: signed("on", nodeKey: "BBBB")))
    }

    /// The app's key exists only once the app said where it lives: before that nothing signs.
    @Test func noKeyBeforeTheAppConfiguresOne() async {
        let approver = AcpmuxMacApprover(mode: .unconfigured)
        #expect(approver.identity == nil)
        #expect(await approver.decision(instance: "i", session: "s", permission: "p", toolCall: "c", option: "yes",
                                        nonce: "n", answers: "") == nil)
        approver.configure(keychainService: nil)
        #expect(approver.identity != nil)
    }

    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}
