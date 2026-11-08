public import CmuxHomeCore
public import CmuxNextActions

/// The palette's picks for this Mac's Chief registry actions (Edit Chief…, Set Chief Model…, Set Chief
/// Effort… and Make Agent a Chief…, where `cmux chief edit|engine|adopt` take an id), read from the Home
/// list's conversations of this Mac: each of its Chiefs has a direct message there
/// (``HomeChiefDirectMessages``), and an agent to adopt is "an agent already in your conversations".
public nonisolated enum HomeChiefPicks {
    /// This Mac's Chiefs, by agent id, once each in the list's order, without the `deleted` ones.
    public static func localChiefs(in rows: [InboxRow], deleted: Set<String> = []) -> [ActionEnumCase] {
        picks(rows) { $0.isChief && !deleted.contains($0.id.rawValue) }
    }

    /// The agents of those conversations that are no Chief, by participant id (`agent_…`, the only
    /// ids `chief.profile.adopt` takes), once each in the list's order.
    public static func adoptableAgents(in rows: [InboxRow]) -> [ActionEnumCase] {
        let chiefs = Set(rows.flatMap { $0.summary.participants.filter(\.isChief).map(\.id) })
        return picks(rows) { $0.kind == .agent && !$0.isChief && !chiefs.contains($0.id) && $0.id.rawValue.hasPrefix("agent_") }
    }

    private static func picks(_ rows: [InboxRow], _ keep: (Participant) -> Bool) -> [ActionEnumCase] {
        var seen = Set<ParticipantID>()
        return rows.flatMap(\.summary.participants).filter { keep($0) && seen.insert($0.id).inserted }.map {
            ActionEnumCase(value: $0.id.rawValue, title: $0.visibleName.isEmpty ? $0.id.rawValue : $0.visibleName)
        }
    }
}
