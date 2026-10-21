import CmuxNextDaemon
import CmuxNextSidebar

extension SidebarMapping {
    /// An agent chat tab's sub-sessions as the sidebar nests them under it
    /// (`sidebar.subsessionNesting`, `SidebarSubsessionRow`): every session its chat's agent
    /// started, at any depth, from acpmux's `startedBy` links (`AgentTurnStateStore`), titled by
    /// its short name, else its chat title, with its live state, unread and queued prompts. None
    /// for any other tab, a chat of another machine, or while the toggle is off.
    func subsessions(_ tab: TabModel, enabled: Bool = SidebarTunables.subsessionNesting.value) -> [SidebarSubsession] {
        guard enabled, let ref = tab.agentSession, ref.session != nil else { return [] }
        return StatusMapping.shared.turns.subsessions(of: ref).map { entry in
            SidebarSubsession(id: entry.session, title: Self.subsessionTitle(entry), state: Self.subsessionState(entry.state),
                              isUnread: entry.facts.unread || entry.state == .done, queued: entry.facts.queued, depth: entry.depth)
        }
    }

    /// `listed` (tab `tab`'s sidebar row) with its sub-sessions.
    func withSubsessions(of tab: TabModel, _ listed: SidebarTab) -> SidebarTab {
        var listed = listed
        listed.subsessions = subsessions(tab)
        return listed
    }

    /// A sub-session's row title: its short name, else its chat title, else its id's start.
    static func subsessionTitle(_ entry: AgentSubsessionEntry) -> String {
        entry.facts.shortName ?? entry.title ?? String(entry.session.prefix(8))
    }

    /// The nested row's state for a sub-session's turn state.
    static func subsessionState(_ state: AgentTurnState?) -> SidebarSubsessionState {
        switch state {
        case .working?: .working
        case .needsInput?: .needsInput
        case .failed?, .lost?: .failed
        case .done?: .done
        case nil: .idle
        }
    }
}
