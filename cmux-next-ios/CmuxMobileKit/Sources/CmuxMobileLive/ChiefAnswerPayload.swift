import CmuxMobileAgentChat
import CmuxMobileChief
import Foundation

/// What the phone's approval key signs for one Chief question answer
/// (cmux-mobile-host `chief_answers.rs` checks the same bytes): the domain, then this
/// Mac, the approver (this phone), the conversation, the question's message
/// and part, the nonce, the expiry and the digest of the answer.
public struct ChiefAnswerPayload: Sendable, Equatable {
    public static let domain = "cmux-mobile-chief-answer-v1"

    public var macDevice: String
    public var approver: String
    public var conversation: String
    public var messageID: String
    public var partIndex: Int
    public var nonce: String
    /// Unix seconds; hostd accepts at most 300 s ahead.
    public var expiresAt: Int
    public var answer: JSONValue

    public init(macDevice: String, approver: String, conversation: String, messageID: String, partIndex: Int,
                nonce: String, expiresAt: Int, answer: JSONValue) {
        self.macDevice = macDevice
        self.approver = approver
        self.conversation = conversation
        self.messageID = messageID
        self.partIndex = partIndex
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.answer = answer
    }

    /// The signed bytes.
    public var message: Data {
        ApprovalPayload.joined(Self.domain, [macDevice, approver, conversation, messageID, String(partIndex), nonce,
                                             String(expiresAt), ApprovalPayload.answersDigest(answer)])
    }

    /// The command's `approval` field carrying `signature`.
    public func approval(signature: Data) -> JSONValue {
        .object(["approver": .string(approver), "nonce": .string(nonce), "expiresAt": .number(Double(expiresAt)),
                 "signature": .string(ApprovalPayload.hex(signature))])
    }
}

/// Signs Chief answers on one linked Mac with this phone's approval key, after
/// Face ID or the passcode (one prompt per answer).
public struct ChiefAnswerSigner: ChiefAnswerSigning {
    public let keys: PhoneKeys
    public let macDevice: String
    public let phoneID: String
    public let now: @Sendable () -> Date

    public init(keys: PhoneKeys, macDevice: String, phoneID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.keys = keys
        self.macDevice = macDevice
        self.phoneID = phoneID
        self.now = now
    }

    public func approval(conversation: String, messageID: String, partIndex: Int, answer: JSONValue) async throws -> JSONValue {
        let payload = ChiefAnswerPayload(
            macDevice: macDevice, approver: phoneID, conversation: conversation, messageID: messageID, partIndex: partIndex,
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            expiresAt: Int(now().timeIntervalSince1970 + ApprovalPayload.lifetime), answer: answer)
        let sign: @Sendable (Data) throws -> Data
        do {
            sign = try await keys.authorizeApproval(reason: String(localized: "Answer Chief's question"))
        } catch PhoneKeys.Failure.cancelled {
            // The sheet says "Face ID was cancelled", not a key error.
            throw ChiefApprovalCancelled()
        }
        return payload.approval(signature: try sign(payload.message))
    }
}
