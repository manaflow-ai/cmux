public import CmuxHomeCore
public import CmuxNextActions

/// The palette's picks for this Mac's Chief registry actions (Edit Chief…, Set Chief Model…, Set Chief
/// Effort… and Make Agent a Chief…, where `cmux chief edit|engine|adopt` take an id), read from the Home
/// list's conversations of this Mac: each of its Chiefs has a direct message there
/// (``HomeChiefDirectMessages``), and an agent to adopt is "an agent already in your conversations".
public nonisolated struct HomeChiefPicks {
    private let conversations: [ConversationSummary]

    /// - Parameter conversations: The Home list's conversations of this Mac, in its order.
    public init(_ conversations: [ConversationSummary]) {
        self.conversations = conversations
    }

    /// This Mac's Chiefs, by agent id, once each in the list's order, without the `deleted` ones.
    public func localChiefs(deleted: Set<String> = []) -> [ActionEnumCase] {
        picks { $0.isChief && !deleted.contains($0.id.rawValue) }
    }

    /// The agents of those conversations that are no Chief, by participant id (`agent_…`, the only
    /// ids `chief.profile.adopt` takes), once each in the list's order.
    public func adoptableAgents() -> [ActionEnumCase] {
        let chiefs = Set(conversations.flatMap { $0.participants.filter(\.isChief).map(\.id) })
        return picks { $0.kind == .agent && !$0.isChief && !chiefs.contains($0.id) && $0.id.rawValue.hasPrefix("agent_") }
    }

    private func picks(_ keep: (Participant) -> Bool) -> [ActionEnumCase] {
        var seen = Set<ParticipantID>()
        return conversations.flatMap(\.participants).filter { keep($0) && seen.insert($0.id).inserted }.map {
            ActionEnumCase(value: $0.id.rawValue, title: $0.visibleName.isEmpty ? $0.id.rawValue : $0.visibleName)
        }
    }
}
