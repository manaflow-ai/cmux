import CmuxNextHistory
import CmuxNextHistoryDaemon

/// The vault's sessions from `AgentHistory`: the agent sessions of every
/// connected machine, as its daemon lists them.
@MainActor
final class AgentHistorySource: VaultSessionSource {
    /// Weak: the services own the vault that owns this source.
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func refresh() async {
        await services?.history.agents.refresh()
    }

    func sessions() -> [AgentSession] {
        services?.history.agents.sessions ?? []
    }

    var isComplete: Bool { services?.history.agents.isComplete ?? true }
    func waitForPending(afterReads reads: Int) async throws { try await DaemonHistoryClient.waitForPending(afterReads: reads) } // the daemon client's own wait

    /// Not ended, and its tab is still on a connected machine.
    func isLive(_ session: AgentSession) -> Bool {
        guard session.endedAt == nil, let tab = session.tab else { return false }
        return services?.locateTabOnAnyMachine(tab) != nil
    }
}
