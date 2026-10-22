import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileNotifications

/// PROTOCOL.md "Sealed pushes and the reply mailbox": the crypto the Mac host
/// (`seal.rs`) and this phone share.
@Suite struct PushSealTests {
    static let context = PushSeal.pushContext(mac: "mac-1", phone: "phone-1", eventId: "p-1")

    @Test func sealsAndOpens() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let sealed = try PushSeal.seal(Data("hello".utf8), to: recipient.publicKey.x963Representation, context: Self.context)
        #expect(!sealed.contains("=") && !sealed.contains("+") && !sealed.contains("/"))
        #expect(try PushSeal.open(sealed, with: recipient, context: Self.context) == Data("hello".utf8))
    }

    @Test func theWireLayoutIsFixed() throws {
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0x33, count: 12))
        let sealed = try PushSeal.seal(Data("abc".utf8), to: recipient.publicKey.x963Representation, context: Self.context,
                                       ephemeral: ephemeral, nonce: nonce)
        let wire = try #require(PushSeal.data(base64url: sealed))
        #expect(wire.count == 1 + 65 + 12 + 3 + 16)
        #expect(wire.first == 1)
        #expect(Data(wire[1..<66]) == ephemeral.publicKey.x963Representation)
        #expect(Data(wire[66..<78]) == Data(repeating: 0x33, count: 12))
        // The same inputs always seal to the same bytes (the shared vector).
        let again = try PushSeal.seal(Data("abc".utf8), to: recipient.publicKey.x963Representation, context: Self.context,
                                      ephemeral: ephemeral, nonce: nonce)
        #expect(again == sealed)
    }

    @Test func refusesAnotherKeyContextOrChangedBytes() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let sealed = try PushSeal.seal(Data("hello".utf8), to: recipient.publicKey.x963Representation, context: Self.context)
        #expect(throws: PushSeal.Failure.openFailed) { try PushSeal.open(sealed, with: P256.KeyAgreement.PrivateKey(), context: Self.context) }
        let other = PushSeal.pushContext(mac: "mac-1", phone: "phone-1", eventId: "p-2")
        #expect(throws: PushSeal.Failure.openFailed) { try PushSeal.open(sealed, with: recipient, context: other) }
        var wire = try #require(PushSeal.data(base64url: sealed))
        wire[wire.count - 20] ^= 0x01
        #expect(throws: PushSeal.Failure.openFailed) { try PushSeal.open(PushSeal.base64url(wire), with: recipient, context: Self.context) }
        #expect(throws: PushSeal.Failure.malformed) { try PushSeal.open("AQ", with: recipient, context: Self.context) }
        #expect(throws: PushSeal.Failure.malformed) { try PushSeal.open("not+base64", with: recipient, context: Self.context) }
    }

    @Test func contextsAreTheDocumentedBytes() {
        #expect(Self.context == Data("cmux-mobile-push-seal-v1\u{0}mac-1\u{0}phone-1\u{0}p-1".utf8))
        #expect(PushSeal.replyContext(mac: "m", phone: "p", replyId: "r") == Data("cmux-mobile-reply-seal-v1\u{0}m\u{0}p\u{0}r".utf8))
    }

    @Test func canonicalJSONMatchesAcpmux() {
        let value: PushJSON = .object(["b": .int(2), "a": .array([.string("x\"\n\u{1}"), .bool(true), .null]), "é": .int(-1)])
        #expect(value.canonical == #"{"a":["x\"\n\u0001",true,null],"b":2,"é":-1}"#)
    }

    /// The Mac host's vectors (cmux-mobile-host `seal.rs`), when that branch is merged in.
    @Test(.enabled(if: SealVectors.load() != nil)) func opensTheMacHostsVectors() throws {
        for vector in try #require(SealVectors.load()) {
            let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: try #require(PushSignature.hexData(vector.recipientPrivate)))
            let context = try #require(PushSignature.hexData(vector.contextHex))
            let opened = try PushSeal.open(vector.sealed, with: recipient, context: context)
            #expect(PushSignature.hex(opened) == vector.plaintextHex, "\(vector.name)")
            if let ephemeralHex = vector.ephemeralPrivate, let nonceHex = vector.nonceHex {
                let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try #require(PushSignature.hexData(ephemeralHex)))
                let nonce = try AES.GCM.Nonce(data: try #require(PushSignature.hexData(nonceHex)))
                let sealed = try PushSeal.seal(opened, to: recipient.publicKey.x963Representation, context: context,
                                               ephemeral: ephemeral, nonce: nonce)
                #expect(sealed == vector.sealed, "\(vector.name)")
            }
        }
    }
}

/// `cmux-next-ios/rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json`.
struct SealVectors: Decodable {
    var name: String
    var recipientPrivate: String
    var ephemeralPrivate: String?
    var nonceHex: String?
    var contextHex: String
    var plaintextHex: String
    var sealed: String

    static func load() -> [SealVectors]? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct File: Decodable { var vectors: [SealVectors] }
        return (try? JSONDecoder().decode(File.self, from: data))?.vectors
    }
}

@Suite struct SealedPushTests {
    static let mac = "mac-1"
    static let phone = "phone-1"

    /// What a Mac host sends a phone: the v2 content sealed to its push key, signed by the Mac.
    static func sealedPush(macKey: P256.Signing.PrivateKey, pushKey: Data, payload: PushPayload, eventId: String = "p-1",
                           signPhone: String = phone) throws -> [AnyHashable: Any] {
        let content = try JSONEncoder().encode(payload)
        let box = try PushSeal.seal(content, to: pushKey, context: PushSeal.pushContext(mac: mac, phone: signPhone, eventId: eventId))
        let sig = try macKey.signature(for: SealedPush.signedMessage(mac: mac, phone: signPhone, eventId: eventId, box: box)).rawRepresentation
        return ["aps": ["alert": ["title": "cmux", "body": "New notification from Mac mini"], "mutable-content": 1],
                "cmuxMobile": ["v": 3, "mac": mac, "macName": "Mac mini", "kind": payload.kind.rawValue, "eventId": eventId,
                               "box": box, "sig": PushSignature.hex(sig), "previews": true] as [String: Any]]
    }

    static func setUp() throws -> (PushKeys, P256.Signing.PrivateKey, Data) {
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        let pushKey = try keys.publicKey(user: "u1")
        let macKey = P256.Signing.PrivateKey()
        keys.trust(mac: mac, identityKey: PushSignature.hex(macKey.publicKey.x963Representation), boxKey: nil, user: "u1", phone: phone)
        return (keys, macKey, pushKey)
    }

    static let question = PushPayload(mac: mac, macName: "Mac mini", kind: .question, eventId: "p-1", agent: "Claude", workspace: "cmux",
                                      sessionId: "s-1", permissionId: "perm-1", title: "Which branch?",
                                      questions: [PushQuestion(question: "Which branch?", options: [.init(label: "main")])],
                                      decisionNonce: "dn-1", personInstance: "pi-1")

    @Test func opensASealedPush() throws {
        let (keys, macKey, pushKey) = try Self.setUp()
        let push = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: Self.question)))
        let payload = try push.open(trust: keys.trust(), keys: keys)
        #expect(payload.questions.first?.question == "Which branch?" && payload.decisionNonce == "dn-1" && payload.personInstance == "pi-1")
        #expect(PushBanner(payload: payload) == PushBanner(title: "Claude asks", subtitle: "cmux · Mac mini", body: "Which branch?"))
    }

    @Test func refusesAForgedOrMisdirectedPush() throws {
        let (keys, macKey, pushKey) = try Self.setUp()
        // Signed by another key (a Worker making up a question).
        let forged = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: P256.Signing.PrivateKey(), pushKey: pushKey, payload: Self.question)))
        #expect(throws: SealedPush.Failure.badSignature) { try forged.open(trust: keys.trust(), keys: keys) }
        // Sealed for another phone id.
        let other = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: Self.question, signPhone: "phone-2")))
        #expect(throws: SealedPush.Failure.badSignature) { try other.open(trust: keys.trust(), keys: keys) }
        // A box copied under another event id.
        var moved = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: Self.question)))
        moved.eventId = "p-2"
        #expect(throws: SealedPush.Failure.badSignature) { try moved.open(trust: keys.trust(), keys: keys) }
        // A Mac this phone never paired, or no trust at all.
        keys.forget(mac: Self.mac)
        let push = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: Self.question)))
        #expect(throws: SealedPush.Failure.unknownMac) { try push.open(trust: keys.trust(), keys: keys) }
        #expect(throws: SealedPush.Failure.unknownMac) { try push.open(trust: nil, keys: keys) }
    }

    @Test func aBoxForAnotherEventIsAMismatch() throws {
        let (keys, macKey, pushKey) = try Self.setUp()
        var payload = Self.question
        payload.eventId = "p-9"
        let push = try #require(SealedPush(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: payload)))
        #expect(throws: SealedPush.Failure.mismatch) { try push.open(trust: keys.trust(), keys: keys) }
    }

    @Test func bannersFollowTheWorker() {
        var p = Self.question
        p.previews = false
        #expect(PushBanner(payload: p) == PushBanner(title: "Claude has a question", body: "Mac mini"))
        let terminal = PushPayload(mac: "m", macName: "Mac mini", kind: .terminal, place: "repo", title: "Build done", body: "exit 0")
        #expect(PushBanner(payload: terminal) == PushBanner(title: "Build done", subtitle: "repo · Mac mini", body: "exit 0"))
        let bare = PushPayload(mac: "m", macName: "Mac mini", kind: .completed, agent: "Codex", place: "repo")
        #expect(PushBanner(payload: bare) == PushBanner(title: "Codex finished", body: "repo · Mac mini"))
        #expect(PushBanner.generic(macName: "Mac mini") == PushBanner(title: "cmux", body: "New notification from Mac mini"))
    }

    @Test func theTrustRecordFollowsTheAccount() throws {
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        keys.trust(mac: "MAC-1", identityKey: "04AA", boxKey: "04BB", user: "u1", phone: "p1")
        #expect(keys.trust() == PushTrust(user: "u1", phone: "p1", macs: ["mac-1": .init(identityKey: "04aa", boxKey: "04bb")]))
        keys.trust(mac: "mac-2", identityKey: "04cc", boxKey: nil, user: "u2", phone: "p2")
        #expect(keys.trust() == PushTrust(user: "u2", phone: "p2", macs: ["mac-2": .init(identityKey: "04cc")]))
        keys.reset(user: "u2")
        #expect(keys.trust() == nil)
    }
}

@Suite struct MailboxReplyTests {
    static let when = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aTextReplyIsSealedToTheMacAndSigned() throws {
        let macBox = P256.KeyAgreement.PrivateKey()
        let phoneKey = P256.Signing.PrivateKey()
        let reply = PushReply(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, mac: "mac-1", kind: .completed,
                              sessionId: "s-1", action: .text("ship it", attachments: []))
        let mailbox = try MailboxReply(reply: reply, phone: "phone-1", nonce: "n1", now: Self.when)
        #expect(mailbox.plaintext.canonical == #"{"action":{"text":"ship it","type":"text"},"expiresAt":1800000600,"id":"00000000-0000-0000-0000-000000000001","issuedAt":1800000000,"kind":"completed","mac":"mac-1","nonce":"n1","phone":"phone-1","target":{"sessionId":"s-1"},"v":1}"#)
        let signature = try phoneKey.signature(for: mailbox.signedMessage).rawRepresentation
        let sealed = try mailbox.sealed(signature: signature, boxKey: PushSignature.hex(macBox.publicKey.x963Representation))
        // What the Mac does: open, take `sig` out, check it over the rest.
        let opened = try PushSeal.open(sealed, with: macBox, context: PushSeal.replyContext(mac: "mac-1", phone: "phone-1", replyId: mailbox.id))
        let json = try JSONDecoder().decode(PushJSON.self, from: opened)
        guard case .object(var object) = json, case .string(let sig)? = object.removeValue(forKey: "sig") else { Issue.record("no sig"); return }
        #expect(PushJSON.object(object) == mailbox.plaintext)
        #expect(PushSignature.verify(key: PushSignature.hex(phoneKey.publicKey.x963Representation), signature: sig,
                                     message: mailbox.signedMessage))
    }

    @Test func whatTheMailboxRefuses() throws {
        let long = PushReply(mac: "m", kind: .terminal, notificationId: "7", action: .text(String(repeating: "x", count: 4097), attachments: []))
        #expect(throws: MailboxReply.Failure.tooLong) { try MailboxReply(reply: long, phone: "p", nonce: "n", now: Self.when) }
        let answer = PushReply(mac: "m", kind: .question, action: .option(0))
        #expect(throws: MailboxReply.Failure.unsupported) { try MailboxReply(reply: answer, phone: "p", nonce: "n", now: Self.when) }
        #expect(!MailboxReply.supports(answer))
        let allow = PushReply(mac: "m", kind: .permission, action: .allow(optionID: "o"))
        #expect(throws: MailboxReply.Failure.unsigned) { try MailboxReply(reply: allow, phone: "p", nonce: "n", now: Self.when) }
        #expect(!MailboxReply.supports(allow))
        let text = try MailboxReply(reply: PushReply(mac: "m", kind: .completed, action: .text("hi", attachments: [])), phone: "p", nonce: "n", now: Self.when)
        #expect(throws: MailboxReply.Failure.noBoxKey) { try text.sealed(signature: Data(), boxKey: nil) }
    }

    @Test func aTerminalReplyNamesItsNotification() throws {
        let payload = PushPayload(mac: "m", kind: .terminal, tabId: "s7", notificationId: "42", title: "Done?", replyable: true)
        #expect(PushActions().plan(for: payload).map(\.action) == [.terminalReply])
        let reply = try #require(PushReply(payload: payload, button: .terminalReply, text: " yes \n"))
        #expect(reply.notificationId == "42" && reply.action == .text("yes", attachments: []))
        let mailbox = try MailboxReply(reply: reply, phone: "p", nonce: "n", now: Self.when)
        #expect(mailbox.plaintext["target"] == .object(["tabId": .string("s7"), "notificationId": .string("42")]))
        // A poster that takes no reply gets no Reply button and no reply.
        var silent = payload
        silent.replyable = false
        #expect(PushActions().plan(for: silent).isEmpty)
        #expect(PushReply(payload: silent, button: .terminalReply, text: "yes") == nil)
        #expect(PushReply(payload: payload, button: .reply, text: "yes") == nil)
    }
}
