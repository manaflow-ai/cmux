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

    /// The Mac host's vectors (cmux-mobile-host `seal.rs`, `gen_seal_vectors.py`):
    /// a box made with the same ephemeral key and nonce matches byte for byte;
    /// ECDSA signatures are randomized, so they are verified, not reproduced.
    @Test func matchesTheMacHostsPushVector() throws {
        let v = try SealVectors.load()
        let push = v.push
        #expect(PushSeal.pushContext(mac: v.mac, phone: v.phone, eventId: push.eventId) == (try v.hex(push.context)))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try v.hex(push.ephemeralScalar))
        let sealed = try PushSeal.seal(Data(push.plaintext.utf8), to: try v.hex(v.phonePushKey), context: try v.hex(push.context),
                                       ephemeral: ephemeral, nonce: try AES.GCM.Nonce(data: try v.hex(push.nonce)))
        #expect(sealed == push.box)
        let phonePush = try P256.KeyAgreement.PrivateKey(rawRepresentation: try v.hex(v.phonePushScalar))
        #expect(phonePush.publicKey.x963Representation == (try v.hex(v.phonePushKey)))
        #expect(try PushSeal.open(push.box, with: phonePush, context: try v.hex(push.context)) == Data(push.plaintext.utf8))
        // The Mac's signature over the box, as the service extension checks it.
        let message = SealedPush.signedMessage(mac: v.mac, phone: v.phone, eventId: push.eventId, box: push.box)
        #expect(message == (try v.hex(push.signatureMessage)))
        #expect(PushSignature.verify(key: v.macIdentityKey, signature: push.signature, message: message))
        // And the whole path: a trust record with the Mac's key opens it into a payload.
        let keys = PushKeys(store: PushMemoryStore(), enclave: false)
        try keys.store.write(phonePush.rawRepresentation, account: "push-key.u1")
        keys.trust(mac: v.mac, identityKey: v.macIdentityKey, boxKey: v.macBoxKey, user: "u1", phone: v.phone)
        let sealedPush = SealedPush(mac: v.mac, kind: .question, eventId: push.eventId, box: push.box, sig: push.signature)
        let payload = try sealedPush.open(trust: keys.trust(), keys: keys)
        #expect(payload.title == "Which branch?" && payload.kind == .question)
    }

    @Test func matchesTheMacHostsReplyVector() throws {
        let v = try SealVectors.load()
        let reply = v.reply
        #expect(PushSeal.replyContext(mac: v.mac, phone: v.phone, replyId: reply.id) == (try v.hex(reply.context)))
        // The phone's canonical JSON is the Mac's: parse it and write it again.
        let parsed = try JSONDecoder().decode(PushJSON.self, from: Data(reply.canonical.utf8))
        #expect(parsed.canonical == reply.canonical)
        #expect(PushSignature.sha256Hex(Data(reply.canonical.utf8)) == reply.digest)
        #expect(PushSeal.joined("cmux-mobile-reply-v1", [v.mac, v.phone, reply.digest]) == (try v.hex(reply.signatureMessage)))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try v.hex(reply.ephemeralScalar))
        let sealed = try PushSeal.seal(Data(reply.plaintext.utf8), to: try v.hex(v.macBoxKey), context: try v.hex(reply.context),
                                       ephemeral: ephemeral, nonce: try AES.GCM.Nonce(data: try v.hex(reply.nonce)))
        #expect(sealed == reply.box)
        let macBox = try P256.KeyAgreement.PrivateKey(rawRepresentation: try v.hex(v.macBoxScalar))
        #expect(macBox.publicKey.x963Representation == (try v.hex(v.macBoxKey)))
        #expect(try PushSeal.open(reply.box, with: macBox, context: try v.hex(reply.context)) == Data(reply.plaintext.utf8))
        // The sealed plaintext is the canonical JSON plus `sig`, and `sig` verifies with the phone's identity key.
        guard case .object(var object) = try JSONDecoder().decode(PushJSON.self, from: Data(reply.plaintext.utf8)),
              case .string(let sig)? = object.removeValue(forKey: "sig") else { Issue.record("no sig"); return }
        #expect(PushJSON.object(object).canonical == reply.canonical)
        #expect(PushSignature.verify(key: v.phoneIdentityKey, signature: sig, message: try v.hex(reply.signatureMessage)))
    }

    /// What this phone's `MailboxReply` writes for the vector's reply is the Mac's canonical text.
    @Test func aMailboxReplyWritesTheVectorsCanonicalText() throws {
        let v = try SealVectors.load()
        let parsed = try JSONDecoder().decode(PushJSON.self, from: Data(v.reply.canonical.utf8))
        guard case .string(let text)? = parsed["action"]?["text"], case .string(let nonce)? = parsed["nonce"],
              case .int(let issued)? = parsed["issuedAt"], case .int(let expires)? = parsed["expiresAt"], case .string(let kind)? = parsed["kind"],
              let kindValue = PushKind(rawValue: kind), case .object(let target)? = parsed["target"] else {
            Issue.record("unexpected vector reply: \(v.reply.canonical)")
            return
        }
        func t(_ k: String) -> String? { if case .string(let s)? = target[k] { s } else { nil } }
        let reply = PushReply(id: try #require(UUID(uuidString: v.reply.id)), mac: v.mac, kind: kindValue, sessionId: t("sessionId"),
                              permissionId: t("permissionId"), conversationId: t("conversationId"), tabId: t("tabId"),
                              notificationId: t("notificationId"), action: .text(text, attachments: []))
        let mailbox = try MailboxReply(reply: reply, phone: v.phone, nonce: nonce, now: Date(timeIntervalSince1970: TimeInterval(issued)),
                                       lifetime: TimeInterval(expires - issued))
        #expect(mailbox.plaintext.canonical == v.reply.canonical)
        #expect(mailbox.signedMessage == (try v.hex(v.reply.signatureMessage)))
    }
}

/// `cmux-next-ios/rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json`.
struct SealVectors: Decodable {
    struct Push: Decodable {
        var eventId, context, ephemeralScalar, nonce, plaintext, box, signatureMessage, signature: String
    }

    struct Reply: Decodable {
        var id, context, ephemeralScalar, nonce, canonical, digest, signatureMessage, plaintext, box: String
    }

    var mac, phone: String
    var macIdentityKey, macBoxScalar, macBoxKey, macBoxMessage, macBoxSignature: String
    var phoneIdentityKey, phonePushScalar, phonePushKey, pushKeyMessage, pushKeySignature: String
    var push: Push
    var reply: Reply

    struct BadHex: Error {}

    func hex(_ text: String) throws -> Data {
        guard let data = PushSignature.hexData(text) else { throw BadHex() }
        return data
    }

    static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json")
    }

    static func load() throws -> SealVectors {
        try JSONDecoder().decode(SealVectors.self, from: try Data(contentsOf: url))
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
        // Unopened, it is no payload: none of its buttons can act.
        #expect(PushPayload(userInfo: try Self.sealedPush(macKey: macKey, pushKey: pushKey, payload: Self.question)) == nil)
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
        // A program's own title never stands where an agent's would (review L6).
        let terminal = PushPayload(mac: "m", macName: "Mac mini", kind: .terminal, place: "repo", title: "Claude needs permission", body: "exit 0")
        #expect(PushBanner(payload: terminal) == PushBanner(title: "Terminal · repo", subtitle: "repo · Mac mini", body: "Claude needs permission: exit 0"))
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
        #expect(mailbox.plaintext.canonical == #"{"action":{"text":"ship it","type":"text"},"expiresAt":1800000540,"id":"00000000-0000-0000-0000-000000000001","issuedAt":1800000000,"kind":"completed","mac":"mac-1","nonce":"n1","phone":"phone-1","target":{"sessionId":"s-1"},"v":1}"#)
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
        let answer = PushReply(mac: "m", kind: .question, action: .option(0, label: "A"))
        #expect(throws: MailboxReply.Failure.unsupported) { try MailboxReply(reply: answer, phone: "p", nonce: "n", now: Self.when) }
        #expect(!MailboxReply.supports(answer))
        // A terminal agent's question has no permission id: its Deny is Escape typed into the
        // terminal, which only the link's screen check may do (review 2, N5).
        #expect(!MailboxReply.supports(PushReply(mac: "m", kind: .question, tabId: "s1", action: .deny(optionID: nil))))
        #expect(MailboxReply.supports(PushReply(mac: "m", kind: .permission, permissionId: "p", action: .deny(optionID: nil))))
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

/// PR B security review H1, M3, L2, L4 and correctness review 1.
@Suite struct PushTrustGateTests {
    static let mac = SealedPushTests.mac

    static func unsealed(_ payload: PushPayload) -> [AnyHashable: Any] { payload.userInfo }

    @Test func anUnsealedPushFromAMacThatSealsActsOnNothing() throws {
        let (keys, macKey, _) = try SealedPushTests.setUp()
        // This Mac proved a box key: it seals.
        keys.trust(mac: Self.mac, identityKey: PushSignature.hex(macKey.publicKey.x963Representation),
                   boxKey: PushSignature.hex(P256.KeyAgreement.PrivateKey().publicKey.x963Representation), user: "u1", phone: SealedPushTests.phone)
        let gate = PushTrustGate(trust: keys.trust(), keys: keys)
        // The service made up a question with swapped labels: shown as a bare route, no buttons.
        let forged = PushPayload(mac: Self.mac, kind: .question, eventId: "p-1", sessionId: "s-1", permissionId: "perm-1",
                                 title: "Cancel deploy?", questions: [PushQuestion(question: "Cancel deploy?", options: [.init(label: "Cancel")])])
        guard case .openOnly(let route) = gate.verdict(userInfo: Self.unsealed(forged), shown: nil) else { Issue.record("acted on"); return }
        #expect(route.questions.isEmpty && route.title == nil && route.sessionId == "s-1")
        // A Mac that never sealed keeps PR A's behavior.
        let other = PushPayload(mac: "mac-old", kind: .completed, sessionId: "s")
        #expect(gate.verdict(userInfo: Self.unsealed(other), shown: nil) == .trusted(other))
    }

    @Test func aSealedPushIsOpenedAgainFromItsBox() throws {
        let (keys, macKey, pushKey) = try SealedPushTests.setUp()
        let gate = PushTrustGate(trust: keys.trust(), keys: keys)
        let raw = try SealedPushTests.sealedPush(macKey: macKey, pushKey: pushKey, payload: SealedPushTests.question)
        // What the service extension leaves: the content it wrote, and the box as it came.
        var forgedContent = PushPayload(mac: Self.mac, kind: .question, eventId: "p-1", sessionId: "s-1", permissionId: "perm-1",
                                        questions: [PushQuestion(question: "x", options: [.init(label: "Swapped")])]).userInfo
        forgedContent[PushTrustGate.sealedKey] = raw[PushPayload.userInfoKey]
        let opened = try #require(SealedPush(userInfo: raw)).open(trust: keys.trust(), keys: keys)
        let banner = PushBanner(payload: opened)
        let shown = PushTrustGate.Shown(title: banner.title, subtitle: banner.subtitle ?? "", body: banner.body,
                                        category: opened.category.rawValue)
        guard case .trusted(let payload) = gate.verdict(userInfo: forgedContent, shown: shown, now: Date()) else { Issue.record("refused"); return }
        // The box's options count, never the content beside it.
        #expect(payload.questions.first?.options.map(\.label) == ["main"])
        // A box signed by another key is refused outright.
        var bad = forgedContent
        bad[PushTrustGate.sealedKey] = try SealedPushTests.sealedPush(macKey: P256.Signing.PrivateKey(), pushKey: pushKey,
                                                                      payload: SealedPushTests.question)[PushPayload.userInfoKey]
        #expect(gate.verdict(userInfo: bad, shown: shown) == .refused)
    }

    /// PR B review 2, B1: a genuine sealed box replayed under a banner and category the
    /// service chose (no `mutable-content`, so the service extension never ran) shows text
    /// the box does not say. Only content the extension wrote from the box acts.
    @Test func aGenuineBoxUnderAForeignBannerActsOnNothing() throws {
        let (keys, macKey, pushKey) = try SealedPushTests.setUp()
        let gate = PushTrustGate(trust: keys.trust(), keys: keys)
        let raw = try SealedPushTests.sealedPush(macKey: macKey, pushKey: pushKey, payload: SealedPushTests.question)
        var info = SealedPushTests.question.userInfo
        info[PushTrustGate.sealedKey] = raw[PushPayload.userInfoKey]
        let opened = try #require(SealedPush(userInfo: raw)).open(trust: keys.trust(), keys: keys)
        let banner = PushBanner(payload: opened)
        // What the extension wrote: acts.
        let written = PushTrustGate.Shown(title: banner.title, subtitle: banner.subtitle ?? "", body: banner.body,
                                          category: opened.category.rawValue)
        guard case .trusted = gate.verdict(userInfo: info, shown: written) else { Issue.record("refused its own content"); return }
        // The service's own words over the genuine box: open only.
        let foreign = PushTrustGate.Shown(title: "Claude needs permission", subtitle: "", body: "read README.md",
                                          category: PushCategory.permission.rawValue)
        guard case .openOnly = gate.verdict(userInfo: info, shown: foreign) else { Issue.record("acted on a foreign banner"); return }
        // The right words with another category (other buttons): open only.
        var recategorized = written
        recategorized.category = PushCategory.permission.rawValue
        guard case .openOnly = gate.verdict(userInfo: info, shown: recategorized) else { Issue.record("acted on another category"); return }
    }

    @Test func anOldPushKeepsItsTapButLosesItsButtons() throws {
        var payload = PushPayload(mac: "mac-old", kind: .completed, sessionId: "s", postedAt: 1_800_000_000)
        let gate = PushTrustGate(trust: nil, keys: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000 + PushTrustGate.maxAge + 1)
        #expect(gate.verdict(userInfo: payload.userInfo, shown: nil, now: now) == .openOnly(payload))
        payload.postedAt = 1_800_000_000 + 10
        #expect(gate.verdict(userInfo: payload.userInfo, shown: nil, now: now) == .trusted(payload))
    }

    @Test func theBoxKeyIsCheckedAgainstThePinnedMacKeyBeforeSealing() throws {
        let macKey = P256.Signing.PrivateKey()
        let identity = PushSignature.hex(macKey.publicKey.x963Representation)
        let box = PushSignature.hex(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let signature = PushSignature.hex(try macKey.signature(for: PushSeal.joined("cmux-mobile-mac-box-v1", ["mac-1", box])).rawRepresentation)
        let good = PushTrust.Mac(identityKey: identity, boxKey: box, boxSignature: signature)
        #expect(try MailboxReply.trustedBoxKey(good, macID: "mac-1", pinnedIdentity: identity) == box)
        // Another box key written into the shared keychain, a pin that differs, no signature: refused.
        let swapped = PushTrust.Mac(identityKey: identity, boxKey: PushSignature.hex(P256.KeyAgreement.PrivateKey().publicKey.x963Representation),
                                    boxSignature: signature)
        #expect(throws: MailboxReply.Failure.untrustedBoxKey) { try MailboxReply.trustedBoxKey(swapped, macID: "mac-1", pinnedIdentity: identity) }
        #expect(throws: MailboxReply.Failure.untrustedBoxKey) { try MailboxReply.trustedBoxKey(good, macID: "mac-1", pinnedIdentity: "04ff") }
        #expect(throws: MailboxReply.Failure.untrustedBoxKey) {
            try MailboxReply.trustedBoxKey(PushTrust.Mac(identityKey: identity, boxKey: box), macID: "mac-1", pinnedIdentity: identity)
        }
    }

    @Test func onlyTheMacsOwnSignatureSaysAReplyWasApplied() throws {
        let macKey = P256.Signing.PrivateKey()
        let pin = PushSignature.hex(macKey.publicKey.x963Representation)
        let sign = { (applied: Bool, reason: String?) in
            PushSignature.hex(try macKey.signature(for: MailboxReply.ackMessage(mac: "mac-1", id: "r1", applied: applied, reason: reason)).rawRepresentation)
        }
        let applied = MailboxReply.verifiedOutcome(state: "applied", reason: nil, sig: try sign(true, nil), mac: "mac-1", id: "r1", pinnedIdentity: pin)
        #expect(applied?.applied == true)
        // The service says applied with no signature, or with the refusal's signature: not taken.
        #expect(MailboxReply.verifiedOutcome(state: "applied", reason: nil, sig: nil, mac: "mac-1", id: "r1", pinnedIdentity: pin) == nil)
        #expect(MailboxReply.verifiedOutcome(state: "applied", reason: nil, sig: try sign(false, "not_pending"), mac: "mac-1", id: "r1",
                                             pinnedIdentity: pin) == nil)
        let refused = MailboxReply.verifiedOutcome(state: "rejected", reason: "not_pending", sig: try sign(false, "not_pending"), mac: "mac-1",
                                                   id: "r1", pinnedIdentity: pin)
        #expect(refused?.applied == false && refused?.reason == "not_pending")
    }

    @Test func aNonceIsWhatTheMacTakes() {
        let nonce = MailboxReply.newNonce()
        // mailbox.rs: 16 to 128 letters or digits.
        #expect(nonce.count == 32 && nonce.allSatisfy { $0.isLetter || $0.isNumber } && nonce == nonce.lowercased())
    }

    @Test func aSealedReplyOverTheServicesLimitIsRefusedOnThePhone() throws {
        let macBox = P256.KeyAgreement.PrivateKey()
        // 4096 bytes of quotes: escaped to twice that, then base64url.
        let reply = PushReply(mac: "m", kind: .completed, sessionId: "s", action: .text(String(repeating: "\"", count: 4096), attachments: []))
        let mailbox = try MailboxReply(reply: reply, phone: "p", nonce: MailboxReply.newNonce(), now: MailboxReplyTests.when)
        let sealed = try mailbox.sealed(signature: Data(repeating: 1, count: 64), boxKey: PushSignature.hex(macBox.publicKey.x963Representation))
        #expect(sealed.count <= MailboxReply.maxSealed)
        // Control characters escape to six bytes each: over the limit, refused here.
        let wide = PushReply(mac: "m", kind: .completed, sessionId: "s", action: .text(String(repeating: "\u{01}", count: 4096), attachments: []))
        let big = try MailboxReply(reply: wide, phone: "p", nonce: MailboxReply.newNonce(), now: MailboxReplyTests.when)
        #expect(throws: MailboxReply.Failure.tooLong) {
            try big.sealed(signature: Data(repeating: 1, count: 64), boxKey: PushSignature.hex(macBox.publicKey.x963Representation))
        }
    }
}

/// PR B security review H2: a terminal reply never goes through the outbox.
@Suite struct OutboxTerminalTests {
    @Test func theOutboxRefusesTextIntoATerminal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = PushOutbox(directory: dir)
        let terminal = PushReply(mac: "m", kind: .terminal, notificationId: "7", action: .text("rm -rf ~", attachments: []))
        #expect(throws: PushOutbox.Refused.self) { try outbox.put(terminal) }
        try outbox.put(PushReply(mac: "m", kind: .completed, sessionId: "s", action: .text("ok", attachments: [])))
        #expect(outbox.takeAll().count == 1)
    }
}
