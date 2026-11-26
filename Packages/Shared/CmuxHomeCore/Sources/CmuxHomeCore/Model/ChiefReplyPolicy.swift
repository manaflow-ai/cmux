public import Foundation

/// When the Chiefs in a group answer: the owner's `settings.wake_policy`
/// (plans/cmux-next/chief-group-chats-DESIGN.md section 3).
///
/// The rule mirrors home-core `wakesFor`, which the owner runs: a Chief that is
/// @mentioned, or whose message is replied to, always answers; otherwise the
/// policy decides. A Chief's own message never wakes a Chief by the policy, so
/// two Chiefs cannot loop (the owner's turn budget also stops them).
///
/// ```swift
/// let who = ChiefReplyPolicy.auto.responders(among: summary.participants, author: me, mentioned: [release])
/// ```
public enum ChiefReplyPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// With one person and one Chief, the Chief answers every message; with more, only a mention or a reply.
    case auto
    /// Only a mention or a reply to the Chief's own message.
    case mentions
    /// Every Chief answers every person's message.
    case all

    /// The owner's default for a new group.
    public static let `default` = ChiefReplyPolicy.auto

    /// The policy a CLI or palette argument names (`auto`, `mentions`, `all`; any case, trimmed); nil otherwise.
    public init?(argument: String) {
        self.init(rawValue: argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The Chiefs that answer a message, in the conversation's order.
    ///
    /// - Parameters:
    ///   - participants: The conversation's current members.
    ///   - author: Who wrote the message.
    ///   - mentioned: The participants the message @mentions.
    ///   - repliedTo: The author of the message it replies to, if any.
    /// - Returns: The ids of the Chiefs that wake.
    public func responders(among participants: [Participant], author: ParticipantID, mentioned: Set<ParticipantID> = [],
                           repliedTo: ParticipantID? = nil) -> [ParticipantID] {
        let current = participants.filter { $0.membership == .active }
        let humans = current.filter { $0.kind == .human }
        let chiefs = current.filter(\.isChief)
        let fromHuman = current.first { $0.id == author }?.kind == .human
        let oneToOne = humans.count == 1 && current.filter { $0.kind == .agent }.count == 1
        return chiefs.compactMap { chief in
            guard chief.id != author else { return nil }
            if mentioned.contains(chief.id) || repliedTo == chief.id { return chief.id }
            guard fromHuman else { return nil }
            switch self {
            case .all: return chief.id
            case .auto: return oneToOne ? chief.id : nil
            case .mentions: return nil
            }
        }
    }
}
