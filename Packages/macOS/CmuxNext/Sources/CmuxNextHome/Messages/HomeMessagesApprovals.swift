import CmuxAgentQuestion
public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextPages
public import Foundation
public import CmuxNextSettings

/// The Messages page's Chief permission cards (`cmux.home.messages.approval.decide`), the decision
/// the native card made (MessagesLabHome `HomeProjection.decideApproval` and `completeApproval`):
/// - `approval.decide {conversation, message, seq, partIndex, allow}` -> `{note, ended}`, `note` one
///   of `allowed`, `denied`, `expired`, `failed`, `allowedNotRecorded`, `deniedNotRecorded` (the
///   page shows CmuxHome's `home.approval.*` strings).
///
/// Only a pending card of a local conversation's Chief, in the narrow shape (one `approval:<digest>`
/// item with allow and deny, a permission id and the request JSON on the allow option), is answered,
/// and only on the person's own click: a key or mouse event the page's view saw (never the page's
/// word) at most five seconds old and newer than the last one spent. The decider answers acpmux's
/// exact pending request through a one-use gate; the answer is then recorded on the card's message
/// (`question.answer`). One decision per card at a time; an ended card takes no other.
@MainActor
public final class HomeMessagesApprovals {
    public static let op = "approval.decide"
    /// How long a click may wait before it answers nothing (the native gesture's five seconds).
    static let gestureLife: TimeInterval = 5

    public enum Note: String, Sendable {
        case allowed, denied, expired, failed, allowedNotRecorded, deniedNotRecorded
    }

    private let store: HomeStore
    private let decider: (any HomeApprovalDeciding)?
    private let now: () -> TimeInterval
    /// The newest gesture spent on a decision: each click answers at most one card once.
    private var latestGesture: TimeInterval = -1
    /// Cards with a decision in flight, and cards answered here (or gone): by question id.
    private var busy: Set<String> = []
    private var ended: Set<String> = []

    /// `decider` answers acpmux (the App's `ChiefApprovalDecider`); nil: every click is refused.
    public init(store: HomeStore, decider: (any HomeApprovalDeciding)?,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.decider = decider
        self.now = now
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not this one.
    public func call(_ name: String, _ fields: [String: JSONValue], context: PageCallContext) async throws -> JSONValue? {
        guard name == Self.op else { return nil }
        guard let conversation = fields["conversation"]?.stringValue, !conversation.isEmpty, conversation.count <= 256,
              let message = fields["message"]?.stringValue, !message.isEmpty, message.count <= 256,
              let seq = fields["seq"]?.doubleValue, seq >= 1, seq < 9e15,
              let index = fields["partIndex"]?.doubleValue, index >= 0, index < 10_000,
              let allow = fields["allow"]?.boolValue else {
            throw PageError.invalidParams("approval.decide takes conversation, message, seq, partIndex and allow")
        }
        let note = await decide(ConversationID(conversation), message: MessageID(message), seq: Seq(seq),
                                partIndex: Int(index), allow: allow, context: context)
        return Self.answer(note)
    }

    static func answer(_ note: Note) -> JSONValue {
        .object(["note": .string(note.rawValue), "ended": .bool(note != .failed)])
    }

    /// The card the page names, read from its owner (its state now, not the page's copy).
    func card(_ id: ConversationID, message: MessageID, seq: Seq, partIndex: Int) async -> (Message, AgentQuestion)? {
        guard let summary = store.summary(id), summary.owner == .local,
              let read = try? await store.source.history(of: id, before: seq + 1, limit: 1),
              let item = read.first(where: { $0.id == message }),
              summary.participants.contains(where: { $0.id == item.author && $0.isChief }),
              case .question(let question)? = item.parts.dropFirst(partIndex).first else { return nil }
        return (item, question)
    }

    /// The request a narrow card stands for (Swift `HomeApprovalRowProvider.digest` and the allow
    /// option's request snapshot), or nil when the question is not one.
    static func request(_ question: AgentQuestion, chief: ParticipantID) -> HomeApprovalRequest? {
        guard question.source.harness == .chief, let permission = question.source.permission,
              question.items.count == 1, let item = question.items.first,
              item.id.hasPrefix("approval:"), !item.multiSelect, !item.allowsOther,
              item.options.count == 2, Set(item.options.map(\.id)) == ["allow", "deny"],
              let requestJSON = item.options.first(where: { $0.id == "allow" })?.preview?.text else { return nil }
        let digest = item.id.dropFirst("approval:".count)
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return HomeApprovalRequest(chief: chief.rawValue, session: question.source.session,
                                   permission: permission, requestJSON: requestJSON)
    }

    func decide(_ id: ConversationID, message: MessageID, seq: Seq, partIndex: Int, allow: Bool,
                context: PageCallContext) async -> Note {
        guard let found = await card(id, message: message, seq: seq, partIndex: partIndex) else { return .failed }
        let (item, question) = found
        guard question.isPending, !ended.contains(question.id) else { return .expired }
        guard let request = Self.request(question, chief: item.author), !busy.contains(question.id) else { return .failed }
        // The person's click only: an event the view saw, unspent and under five seconds old.
        guard context.userGesture, let event = context.gestureEvent, event > latestGesture,
              (0..<Self.gestureLife).contains(now() - event), let decider else { return .failed }
        latestGesture = event
        busy.insert(question.id)
        defer { busy.remove(question.id) }
        let gate = HomeApprovalWriteGate(deadline: event + Self.gestureLife)
        let decision = await decider.decide(request, allow: allow, through: { bytes in gate.write(bytes) })
        gate.cancel()
        switch decision {
        case .refused: return .failed
        case .expired:
            ended.insert(question.id)
            return .expired
        case .answered:
            ended.insert(question.id)
        }
        // No answer is recorded until acpmux took it; an answered request stays ended even when this fails.
        guard let only = question.items.first else { return allow ? .allowed : .denied }
        let answer = AgentQuestionAnswer(selections: [only.id: AgentQuestionAnswer.Selection(optionIDs: [allow ? "allow" : "deny"])])
        do {
            _ = try await store.perform(.answerQuestion(message: item.id, conversation: id, partIndex: partIndex, answer: answer))
            return allow ? .allowed : .denied
        } catch {
            return allow ? .allowedNotRecorded : .deniedNotRecorded
        }
    }
}
