import CmuxNextHistory

/// The vault's sessions from `AgentHistory`: the agent hooks' records in the
/// session journal of every connected machine.
@MainActor
final class AgentHistorySource: VaultSessionSource {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func refresh() async {
        await services.history.agents.refresh()
    }

    func sessions() -> [AgentSession] {
        services.history.agents.sessions
    }

    /// Not ended, and its tab is still on a connected machine.
    func isLive(_ session: AgentSession) -> Bool {
        guard session.endedAt == nil, let tab = session.tab else { return false }
        return services.locateTab(tab) != nil
    }
}
