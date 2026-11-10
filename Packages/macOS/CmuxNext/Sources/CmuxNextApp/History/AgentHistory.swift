import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation
import os

/// Agent sessions of each connected machine (plans/cmux-next/history.md 2,
/// `agent`) for the vault, the agents palette page and resume by id: every
/// machine, each session with its tab and terminal. A daemon lists its
/// sessions whole (`history-agent-sessions-v1`), also those whose journal
/// records retention deleted; only an older daemon's journal is folded here
/// (`MachineAgentSessions`). A caller asks (`refresh`), so nothing polls.
final class AgentHistory {
    private unowned let services: AppServices
    var machines: [String: MachineAgentSessions] = [:] // per machine (tests fill one)
    private var refreshing: Task<Void, Never>?
    /// Hidden by Clear History or Remove from History (the journal is
    /// append-only); the daemon history module writes the hides.
    let hidden: HiddenHistoryStore
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    init(services: AppServices, hidden: HiddenHistoryStore) {
        self.services = services
        self.hidden = hidden
    }

    /// Reads the agent sessions of every connected machine. Concurrent calls share one read.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        // The owner's daemons are read before the first suspension, so a weak capture is enough.
        let task = Task { [weak self] in _ = await self?.readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readAll() async {
        for daemon in services.machines.daemons {
            guard case .connected = daemon.store.connectionState else { continue }
            let machine = daemon.machineID
            var sessions = machines[machine] ?? MachineAgentSessions(machine: machine)
            if daemon.supports(DaemonHistoryClient.agentSessionsCapability), let connection = daemon.connection {
                await sessions.read(list: DaemonHistoryClient(connection: connection))
            } else if daemon.supports("session-journal-v1"), let endpoint = try? await daemon.endpoint() {
                do { try await sessions.read(journal: endpoint.socketPath) } catch {
                    logger.info("agent history: journal read on \(machine, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            } else { continue }
            machines[machine] = sessions
        }
    }

    /// Every known session, newest activity first, minus hidden ones.
    var sessions: [AgentSession] {
        machines.values.flatMap(\.sessions)
            .filter { !hidden.document.hides($0.qualifiedID, activeAt: $0.lastActivityAt, kind: "agent") }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func session(id: String) -> AgentSession? {
        sessions.first { $0.sessionID == id || $0.qualifiedID == id }
    }
}
