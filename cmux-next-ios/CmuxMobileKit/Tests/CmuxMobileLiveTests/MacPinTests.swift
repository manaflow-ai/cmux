import CmuxMobileAgentChat
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// #13742 draft gaps 1 and 2: Chief answers are signed over the bytes cmux-mobile-host
/// checks, and a paired Mac must prove the identity key this phone pinned.
@Suite struct ChiefAnswerPayloadTests {
    @Test func messageMatchesHostd() {
        // The same vector is in cmux-mobile-host `chief_answers::tests::the_message_is_fixed`.
        let answer: JSONValue = .object(["selections": .object(["q1": .array([.string("b"), .string("a")])]), "note": .string("ok")])
        #expect(ApprovalPayload.answersDigest(answer) == "cb8e07eaf77edb7c15c3ceb327ec738655893099180928f4d3ce7d8958716d3e")
        let payload = ChiefAnswerPayload(macDevice: "mac-1", approver: "phone-1", conversation: "conv_A", messageID: "msg_B",
                                         partIndex: 2, nonce: "n0n0n0n0n0n0n0n0", expiresAt: 1_800_000_000, answer: answer)
        #expect(payload.message.starts(with: Data("cmux-mobile-chief-answer-v1\u{0}".utf8)))
        #expect(ApprovalPayloadTests.sha256(payload.message) == "efdb94cfaf0c3176d7286d56d9f43b3bc0320bfec0fa026689e51f3a3074b6fb")
        let approval = payload.approval(signature: Data([0xAB, 0x01]))
        #expect(approval == .object(["approver": .string("phone-1"), "nonce": .string("n0n0n0n0n0n0n0n0"),
                                     "expiresAt": .number(1_800_000_000), "signature": .string("ab01")]))
    }
}

@Suite struct MacPinTests {
    static let mac = "mac-1"
    static let phone = "phone-1"
    static let phoneNonce = "pinnonce0123456789abcdef"

    /// A challenge frame as cmux-mobile-host sends it, its proof made by `key`.
    static func challenge(_ key: P256.Signing.PrivateKey?, nonce: String = "c0ffee", provedNonce: String = phoneNonce) -> JSONValue {
        var object: [String: JSONValue] = ["challenge": .string(nonce), "mac": .string(mac)]
        if let key {
            let message = MacPins.proofMessage(mac: mac, phone: phone, phoneNonce: provedNonce, challenge: nonce)
            let signature = try! key.signature(for: message).rawRepresentation
            object["macKey"] = .string(ApprovalPayload.hex(key.publicKey.x963Representation))
            object["macSignature"] = .string(ApprovalPayload.hex(signature))
        }
        return .object(object)
    }

    static func check(_ frame: JSONValue, pinned: String?) -> LinkPairing.MacProof {
        LinkPairing.check(frame, mac: mac, phone: phone, macNonce: phoneNonce, challenge: frame["challenge"]?.stringValue ?? "",
                          pinned: pinned)
    }

    @Test func aMacProvesItsKeyAndAChangedKeyIsRefused() {
        let key = P256.Signing.PrivateKey()
        let hexKey = ApprovalPayload.hex(key.publicKey.x963Representation)
        #expect(Self.check(Self.challenge(key), pinned: nil) == .proven(hexKey))
        #expect(Self.check(Self.challenge(key), pinned: hexKey) == .proven(hexKey))
        // Another key for a pinned Mac: refused, with the warning.
        #expect(Self.check(Self.challenge(P256.Signing.PrivateKey()), pinned: hexKey) == .refused(LinkPairing.changed))
        // No proof for a pinned Mac: refused; for an older, unpinned Mac: allowed, unpinned.
        #expect(Self.check(Self.challenge(nil), pinned: hexKey) == .refused(LinkPairing.changed))
        #expect(Self.check(Self.challenge(nil), pinned: nil) == .unproven)
        // A proof over another nonce (a replay) is invalid.
        let replay = Self.check(Self.challenge(key, provedNonce: "othernonce0123456789"), pinned: nil)
        #expect(replay == .refused(LinkError(code: "bad_mac_proof", message: "The Mac's identity proof is invalid")))
        #expect(LinkPairing.refusalText(LinkPairing.changed).hasPrefix("This Mac's identity changed"))
    }

    @Test func pinsPersistAndRemovingAMacForgetsIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pins = MacPins(file: file)
        pins.pin("04ab", for: "MAC-1")
        #expect(MacPins(file: file).key(for: "mac-1") == "04ab")
        pins.forget("mac-1")
        #expect(MacPins(file: file).key(for: "mac-1") == nil)
    }

    /// One `auth` channel that sends `first`, then answers a signature with `{"ok":true}`.
    final class ScriptedAuth: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private var frames: [Data]
        init(_ frames: [JSONValue]) { self.frames = frames.map { try! JSONEncoder().encode($0) } }
        func send(_ data: Data) async throws { frames.append(Data(#"{"ok":true}"#.utf8)) }
        func receive() async throws -> Data? { frames.isEmpty ? nil : frames.removeFirst() }
        func close(code: String, reason: String) async {}
    }

    /// End to end on the phone: a Mac whose key changed, or that answers `ok`
    /// with no proof at all, is refused before this phone signs anything.
    @Test func pairingRefusesAMacThatCannotProveItsPinnedKey() async {
        let pins = MacPins(file: nil)
        pins.pin(ApprovalPayload.hex(P256.Signing.PrivateKey().publicKey.x963Representation), for: Self.mac)
        let pairing = LinkPairing(keys: PhoneKeys(service: "test.unused"), phoneID: Self.phone, name: "iPhone", pins: pins)
        for script in [[Self.challenge(P256.Signing.PrivateKey())], [JSONValue.object(["ok": .bool(true)])]] {
            let opened = LinkPairing.Opened(channel: ScriptedAuth(script), identity: "04aa", approval: "04bb", macNonce: Self.phoneNonce)
            let outcome = await pairing.finish(.success(opened), macID: Self.mac) {}
            #expect(outcome == .refused(LinkPairing.changed))
        }
    }
}

/// New Browser Tab only for a Mac that streams browser tabs (`browser-stream-v1`).
@Suite struct BrowserTabOptionTests {
    @Test func aMacThatSaysItCannotStreamHidesNewBrowserTab() {
        #expect(LiveWorkspaceCreationBackend.streamsBrowser(nil))
        #expect(LiveWorkspaceCreationBackend.streamsBrowser([]))
        #expect(LiveWorkspaceCreationBackend.streamsBrowser(["removal-v1", "browser-stream-v1"]))
        #expect(!LiveWorkspaceCreationBackend.streamsBrowser(["removal-v1"]))
    }
}
