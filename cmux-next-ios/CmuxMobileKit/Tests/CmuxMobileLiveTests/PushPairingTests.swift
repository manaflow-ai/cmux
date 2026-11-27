import CmuxMobileAgentChat
import CmuxMobileNotifications
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// PROTOCOL.md "Keys at pairing" (PR B): the phone vouches for its push key
/// with its identity key, and takes the Mac's box key only when the Mac's
/// identity key signed it.
@Suite struct PushPairingTests {
    static let mac = "mac-1"

    @Test func thePushKeyIsSignedByTheIdentityKey() throws {
        let keys = PhoneKeys(userID: "u1", service: "test.push.\(UUID())", store: MemorySecretStore(), enclave: false)
        let push = PushKeys(store: PushMemoryStore(), enclave: false)
        let pairing = LinkPairing(keys: keys, phoneID: "phone-1", name: "iPhone", pins: MacPins(file: nil), push: push)
        let args = try #require(pairing.pushKeyArgs(mac: Self.mac))
        let pushKey = try #require(args["pushKey"])
        #expect(pushKey == PushSignature.hex(try push.publicKey(user: "u1")))
        let identity = try keys.publicKeys().identity
        #expect(MacPins.verify(key: identity, signature: try #require(args["pushKeySignature"]),
                               message: LinkPairing.pushKeyMessage(mac: Self.mac, phone: "phone-1", pushKey: pushKey)))
        #expect(LinkPairing.pushKeyMessage(mac: "m", phone: "p", pushKey: "04") == Data("cmux-mobile-push-key-v1\u{0}m\u{0}p\u{0}04".utf8))
        // Without a push key store (no shared keychain group): no push key, pushes stay unsealed.
        #expect(LinkPairing(keys: keys, phoneID: "phone-1", name: "iPhone", pins: MacPins(file: nil)).pushKeyArgs(mac: Self.mac) == nil)
    }

    @Test func theBoxKeyCountsOnlyWithTheMacsSignature() throws {
        let identity = P256.Signing.PrivateKey()
        let identityHex = ApprovalPayload.hex(identity.publicKey.x963Representation)
        let box = ApprovalPayload.hex(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        func frame(signedBy key: P256.Signing.PrivateKey, box: String) throws -> JSONValue {
            let signature = try key.signature(for: LinkPairing.boxKeyMessage(mac: Self.mac, boxKey: box)).rawRepresentation
            return .object(["macBoxKey": .string(box), "macBoxSignature": .string(ApprovalPayload.hex(signature))])
        }
        #expect(LinkPairing.boxKey(try frame(signedBy: identity, box: box), mac: Self.mac, identityKey: identityHex) == box)
        // Signed by another key, for another Mac, with no proven identity, or not a point: none.
        #expect(LinkPairing.boxKey(try frame(signedBy: P256.Signing.PrivateKey(), box: box), mac: Self.mac, identityKey: identityHex) == nil)
        #expect(LinkPairing.boxKey(try frame(signedBy: identity, box: box), mac: "mac-2", identityKey: identityHex) == nil)
        #expect(LinkPairing.boxKey(try frame(signedBy: identity, box: box), mac: Self.mac, identityKey: nil) == nil)
        #expect(LinkPairing.boxKey(try frame(signedBy: identity, box: "04" + String(repeating: "00", count: 64)), mac: Self.mac, identityKey: identityHex) == nil)
        #expect(LinkPairing.boxKeyMessage(mac: "m", boxKey: "04") == Data("cmux-mobile-mac-box-v1\u{0}m\u{0}04".utf8))
    }

    /// The Mac host's vectors: the push key and box key statements are the same bytes, and their signatures verify.
    @Test func matchesTheMacHostsKeyStatements() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json")
        let v = try JSONDecoder().decode([String: JSONValue].self, from: try Data(contentsOf: url))
        func s(_ k: String) throws -> String { try #require(v[k]?.stringValue) }
        let mac = try s("mac"), phone = try s("phone")
        #expect(PushSignature.hex(LinkPairing.pushKeyMessage(mac: mac, phone: phone, pushKey: try s("phonePushKey"))) == (try s("pushKeyMessage")))
        #expect(MacPins.verify(key: try s("phoneIdentityKey"), signature: try s("pushKeySignature"),
                               message: LinkPairing.pushKeyMessage(mac: mac, phone: phone, pushKey: try s("phonePushKey"))))
        #expect(PushSignature.hex(LinkPairing.boxKeyMessage(mac: mac, boxKey: try s("macBoxKey"))) == (try s("macBoxMessage")))
        let frame: JSONValue = .object(["macBoxKey": .string(try s("macBoxKey")), "macBoxSignature": .string(try s("macBoxSignature"))])
        #expect(LinkPairing.boxKey(frame, mac: mac, identityKey: try s("macIdentityKey")) == (try s("macBoxKey")))
    }
}
