import CmuxNextHistory
import CmuxNextHistoryDaemon
import CmuxNextPages
import Foundation

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

    /// The daemon client's own wait between two reads of a list that is not complete.
    func waitForPending(afterReads reads: Int) async throws {
        try await DaemonHistoryClient.waitForPending(afterReads: reads)
    }

    /// Not ended, and its tab is still on a connected machine.
    func isLive(_ session: AgentSession) -> Bool {
        guard session.endedAt == nil, let tab = session.tab else { return false }
        return services?.locateTabOnAnyMachine(tab) != nil
    }
}

extension SessionVault {
    /// The app's vault: the link router and the localized row titles.
    convenience init(source: any VaultSessionSource, pullRequests: VaultPullRequests = VaultPullRequests(),
                     copyText: @escaping @MainActor (String) -> Void = SessionVault.writeGeneralPasteboard,
                     openURL: @escaping @MainActor (URL) -> Void = { _ = LinkRouter.shared.open($0) }) {
        self.init(source: source, pullRequests: pullRequests, copyText: copyText, openURL: openURL,
                  title: { HistoryAppStrings.agentTitle(provider: $0.provider, cwd: $0.cwd) })
    }
}
