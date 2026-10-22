import Foundation

/// A reply that goes through the cmux service's mailbox when the Mac's link
/// is out of reach (PROTOCOL.md "Reply mailbox", verify/notifications-trust.md).
/// Sealed to the Mac's box key and signed by this phone's identity key: the
/// service can hold it, never read, change or forge it.
public struct MailboxReply: Sendable, Equatable {
    public enum Failure: Error, Equatable, Sendable {
        /// The Mac proved no box key (an older Mac): only the link reaches it.
        case noBoxKey
        /// This kind of reply can't go through the mailbox (a question's
        /// answers need the prompt the link reads).
        case unsupported
        /// Text over the limit.
        case tooLong
        /// An Allow from a push that carried no `decisionNonce` (an unsealed push).
        case unsigned
    }

    /// At most this long a reply stays valid.
    public static let lifetime: TimeInterval = 600
    /// At most this many bytes of text.
    public static let maxTextBytes = 4096

    public var id: String
    public var mac: String
    public var phone: String
    public var plaintext: PushJSON

    /// The plaintext of `reply` from `phone` (without `sig`). `approval` is
    /// the acpmux `_meta.acpmux` an Allow carries (signed after Face ID).
    /// `lifetime` is capped at `MailboxReply.lifetime` (the Mac refuses longer).
    public init(reply: PushReply, phone: String, nonce: String, now: Date, approval: PushJSON? = nil,
                lifetime: TimeInterval = MailboxReply.lifetime) throws {
        let action: [String: PushJSON]
        switch reply.action {
        case .text(let text, let attachments):
            guard attachments.isEmpty else { throw Failure.unsupported }
            guard text.utf8.count <= Self.maxTextBytes else { throw Failure.tooLong }
            action = ["type": .string("text"), "text": .string(text)]
        case .deny(let optionID):
            action = ["type": .string("deny")].merging(optionID.map { ["optionId": .string($0)] } ?? [:]) { a, _ in a }
        case .allow(let optionID):
            guard approval != nil else { throw Failure.unsigned }
            action = ["type": .string("allow"), "optionId": .string(optionID)]
        case .option, .answers:
            throw Failure.unsupported
        }
        var target: [String: PushJSON] = [:]
        for (key, value) in [("sessionId", reply.sessionId), ("permissionId", reply.permissionId),
                             ("conversationId", reply.conversationId), ("tabId", reply.tabId),
                             ("notificationId", reply.notificationId)] {
            if let value { target[key] = .string(value) }
        }
        let issued = Int64(now.timeIntervalSince1970)
        var object: [String: PushJSON] = [
            "v": .int(1), "id": .string(reply.id.uuidString.lowercased()), "mac": .string(reply.mac), "phone": .string(phone),
            "kind": .string(reply.kind.rawValue), "target": .object(target), "action": .object(action), "nonce": .string(nonce),
            "issuedAt": .int(issued), "expiresAt": .int(issued + Int64(min(max(lifetime, 1), Self.lifetime))),
        ]
        if let approval { object["approval"] = approval }
        id = reply.id.uuidString.lowercased()
        mac = reply.mac
        self.phone = phone
        plaintext = .object(object)
    }

    /// What the phone's identity key signs: the domain, the Mac, the phone
    /// and the SHA-256 (lowercase hex) of the canonical plaintext without `sig`.
    public var signedMessage: Data {
        PushSeal.joined("cmux-mobile-reply-v1", [mac, phone, PushSignature.sha256Hex(Data(plaintext.canonical.utf8))])
    }

    /// The sealed body for `POST /v1/devices/:mac/mailbox`, with `signature`
    /// (raw `r || s` over `signedMessage`) added as `sig`.
    public func sealed(signature: Data, boxKey: String?) throws -> String {
        guard let boxKey, let recipient = PushSignature.hexData(boxKey) else { throw Failure.noBoxKey }
        guard case .object(var object) = plaintext else { throw Failure.unsupported }
        object["sig"] = .string(PushSignature.hex(signature))
        return try PushSeal.seal(Data(PushJSON.object(object).canonical.utf8), to: recipient,
                                 context: PushSeal.replyContext(mac: mac, phone: phone, replyId: id))
    }

    /// Whether a reply of this kind can go through the mailbox at all.
    public static func supports(_ reply: PushReply) -> Bool {
        switch reply.action {
        case .text(_, let attachments): attachments.isEmpty
        case .deny: true
        case .allow: reply.decisionNonce != nil && reply.personInstance != nil
        case .option, .answers: false
        }
    }
}
