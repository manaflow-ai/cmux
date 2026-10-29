import CmuxAgentQuestion
import CmuxConversationCore
import CmuxMobileAgentChat
import Foundation

/// Chief's questions in its conversation (cmux-tui `question` parts) and the
/// phone's answers to them. An answer counts on the Mac only with this
/// iPhone's Face ID approval (cmux-mobile-host `chief_answers.rs`), so the phone
/// says "Waiting for Face ID…" until the approval is signed, "Sending…"
/// until the Mac stored the answer, and never claims it was sent before.

/// Where a backend publishes the conversation's questions, newest last.
/// Thread-safe: the backend writes from its actor, the session reads on
/// the main actor.
public final class ChiefQuestionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var questions: [String: (seq: Int, question: AgentQuestion)] = [:]
    private var handler: (@Sendable ([AgentQuestion]) -> Void)?

    public init() {}

    /// Every question, in message order.
    public var current: [AgentQuestion] {
        lock.withLock { questions.values.sorted { ($0.seq, $0.question.id) < ($1.seq, $1.question.id) }.map(\.question) }
    }

    /// Calls `handler` with the list now and after every change.
    public func observe(_ handler: @escaping @Sendable ([AgentQuestion]) -> Void) {
        lock.withLock { self.handler = handler }
        handler(current)
    }

    /// Records `message`'s question parts (pending, answered or cancelled).
    /// With `messageID`, the message's questions not in `found` are gone
    /// (it was retracted or edited), so no bar asks a question that left.
    func update(_ found: [AgentQuestion], seq: Int, messageID: String? = nil) {
        let handler: (@Sendable ([AgentQuestion]) -> Void)? = lock.withLock {
            var changed = false
            if let messageID {
                let kept = Set(found.map(\.id))
                let prefix = "\(messageID)#"
                for id in questions.keys where id.hasPrefix(prefix) && !kept.contains(id) {
                    questions[id] = nil
                    changed = true
                }
            }
            for question in found where questions[question.id]?.question != question {
                questions[question.id] = (seq, question)
                changed = true
            }
            return changed ? self.handler : nil
        }
        handler?(current)
    }

    /// The question parts of one owner `Message` object.
    static func questions(in message: [String: Any]) -> (seq: Int, questions: [AgentQuestion]) {
        guard let id = message["id"] as? String else { return (0, []) }
        let seq = (message["seq"] as? NSNumber)?.intValue ?? 0
        // A retracted message's questions are gone with it.
        guard message["retracted_at"] == nil || message["retracted_at"] is NSNull else { return (seq, []) }
        let parts = message["parts"] as? [[String: Any]] ?? []
        let found = parts.enumerated().compactMap { index, part -> AgentQuestion? in
            guard part["type"] as? String == "question",
                  let data = try? JSONSerialization.data(withJSONObject: part),
                  let json = try? AgentQuestionJSON(data: data) else { return nil }
            return AgentQuestion(conversationPart: json, messageID: id, partIndex: index)
        }
        return (seq, found)
    }
}

/// A backend whose Chief can ask questions the phone answers.
public protocol ChiefQuestionSource: AnyObject, Sendable {
    var questionFeed: ChiefQuestionFeed { get }
    /// Fetches the conversation again, so the feed says whether the Mac
    /// has an answer whose reply was lost.
    func recheckQuestions() async throws
    /// Answers `question`. `approved` runs once Face ID approved and the
    /// answer is signed, before it is sent; the call returns once the Mac
    /// stored it, and throws otherwise.
    func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer, signer: (any ChiefAnswerSigning)?,
                approved: @escaping @Sendable () -> Void) async throws
}

/// Face ID (or the passcode) was cancelled: nothing was signed or sent.
public struct ChiefApprovalCancelled: Error, Equatable, Sendable {
    public init() {}
}

/// No approval key or paired Mac to sign with.
public struct ChiefApprovalUnavailable: Error, Equatable, Sendable {
    public init() {}
}

/// One answer's progress. Pure, so the order of states is testable: an
/// answer is `sent` only after the Mac stored it, "Not sent" is said only
/// when it truly was not (nothing signed, or the Mac refused it), and a
/// second Answer while one is in flight does nothing.
public struct ChiefAnswerFlow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Face ID is up (or about to be): nothing is signed yet.
        case waitingForApproval
        /// Signed and on its way; the Mac has not answered yet.
        case sending
        /// The Mac stored the answer.
        case sent
        /// Not sent (nothing was signed, or the Mac refused it); `text` says why.
        case failed(String)
        /// The answer went out but the reply was lost (the link dropped):
        /// the Mac may have it. Check asks the Mac again.
        case unconfirmed
        /// Asking the Mac whether it has the answer.
        case checking
    }

    public private(set) var state: State = .idle

    public init() {}

    public var isBusy: Bool { state == .waitingForApproval || state == .sending || state == .checking }

    /// The person tapped Answer. False (and no change) while one is in
    /// flight, done, or possibly done (unconfirmed: Check first).
    public mutating func begin() -> Bool {
        switch state {
        case .idle, .failed: state = .waitingForApproval; return true
        case .waitingForApproval, .sending, .sent, .unconfirmed, .checking: return false
        }
    }

    /// Face ID approved and the answer is signed.
    public mutating func approved() {
        if state == .waitingForApproval { state = .sending }
    }

    /// The Mac stored the answer (its reply, or a check found it answered).
    public mutating func stored() {
        if isBusy || state == .unconfirmed { state = .sent }
    }

    /// The answer failed. Before signing, or a refusal from the Mac: not
    /// sent. Anything else after it went out: unconfirmed (R2-5).
    public mutating func failed(_ error: any Error) {
        switch state {
        case .waitingForApproval:
            state = .failed(Self.text(error))
        case .sending, .checking:
            state = Self.isRefusal(error) ? .failed(Self.text(error)) : .unconfirmed
        default:
            break
        }
    }

    /// The person tapped Check.
    public mutating func beginCheck() -> Bool {
        guard state == .unconfirmed else { return false }
        state = .checking
        return true
    }

    /// The Mac answered the check: it still waits for an answer, so this
    /// one never reached it.
    public mutating func checkedStillPending() {
        if state == .checking { state = .failed(String(localized: "Not sent: your Mac doesn't have this answer. Try again.")) }
    }

    /// A refusal the Mac returned (the op reached it and was not stored).
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? ConversationBackendError)?.code == -32000
    }

    /// What the sheet says for a failure.
    public static func text(_ error: any Error) -> String {
        switch error {
        case is ChiefApprovalCancelled: return String(localized: "Not sent: Face ID was cancelled.")
        case is ChiefApprovalUnavailable: return String(localized: "Not sent: this iPhone isn't paired with the Mac yet.")
        case let refused as ConversationBackendError where refused.message.contains("question_closed"):
            return String(localized: "Chief no longer needs this answer.")
        case let refused as ConversationBackendError where refused.message.contains("forbidden"):
            return String(localized: "Not sent: your Mac didn't accept this iPhone's approval.")
        case let refused as ConversationBackendError where refused.message.contains("invalid_answer"):
            return String(localized: "Not sent: the answer doesn't fit the question.")
        default: return String(localized: "Not sent: Chief on your Mac didn't take the answer. Try again.")
        }
    }

    /// The status line under the question, or nil when there is none.
    public var statusText: String? {
        switch state {
        case .idle: nil
        case .waitingForApproval: String(localized: "Waiting for Face ID…")
        case .sending: String(localized: "Sending…")
        case .sent: String(localized: "Sent")
        case .failed(let text): text
        case .unconfirmed: String(localized: "Couldn't confirm. Chief may have it.")
        case .checking: String(localized: "Checking with your Mac…")
        }
    }
}

/// A Chief question's address in its conversation: `<message id>#<part index>`.
struct ChiefQuestionAddress: Equatable {
    var messageID: String
    var partIndex: Int

    init?(_ id: String) {
        guard let hash = id.lastIndex(of: "#"), let index = Int(id[id.index(after: hash)...]) else { return nil }
        messageID = String(id[..<hash])
        partIndex = index
    }
}

extension AgentQuestionAnswer {
    /// The `question.answer` op's `answer` as the transport's JSON.
    var conversationJSON: JSONValue {
        get throws {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(conversationAnswer))
        }
    }
}

/// Wraps a signer so the flow learns when Face ID approved, before sending.
struct ChiefApprovalNotifyingSigner: ChiefAnswerSigning {
    let signer: any ChiefAnswerSigning
    let approved: @Sendable () -> Void

    func approval(conversation: String, messageID: String, partIndex: Int, answer: JSONValue) async throws -> JSONValue {
        let approval = try await signer.approval(conversation: conversation, messageID: messageID, partIndex: partIndex, answer: answer)
        approved()
        return approval
    }
}

extension ChiefDaemonBackend: ChiefQuestionSource {
    public var questionFeed: ChiefQuestionFeed { core.questionFeed }

    public func recheckQuestions() async throws {
        try await core.resync()
    }

    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer, signer: (any ChiefAnswerSigning)?,
                       approved: @escaping @Sendable () -> Void) async throws {
        guard let signer else { throw ChiefApprovalUnavailable() }
        guard let address = ChiefQuestionAddress(question.id) else {
            throw ConversationBackendError(code: -32602, message: "not a conversation question")
        }
        _ = try await answerQuestion(messageID: address.messageID, partIndex: address.partIndex,
                                     answer: try answer.conversationJSON,
                                     signer: ChiefApprovalNotifyingSigner(signer: signer, approved: approved))
    }
}
