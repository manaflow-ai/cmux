import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import os

/// Agent sessions from each connected machine's session journal
/// (plans/cmux-next/history.md 2, `agent`). The daemon owns the facts; this
/// keeps one `AgentSessionFold` per machine and reads only the records
/// after its cursor when a history list asks (`refresh`), so nothing polls.
final class AgentHistory {
    private unowned let services: AppServices
    private var folds: [String: AgentSessionFold] = [:]
    private var generations: [String: String] = [:]
    private var refreshing: Task<Void, Never>?
    /// Hidden by Clear History (the journal is append-only): sessions whose
    /// last activity falls in a cleared range, and single sessions. In
    /// memory for this app run.
    private var hiddenRanges: [ClosedRange<Date>] = []
    private var hiddenSessions: Set<String> = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    init(services: AppServices) {
        self.services = services
    }

    /// Reads new agent records from every connected machine that serves the
    /// session journal. Concurrent calls share one read.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readAll() async {
        for daemon in services.machines.daemons where daemon.supports("session-journal-v1") {
            guard case .connected = daemon.store.connectionState, let endpoint = try? await daemon.endpoint() else { continue }
            let machine = daemon.machineID
            let fold = folds[machine] ?? AgentSessionFold(machine: machine)
            let cursor = generations[machine].map { (generation: $0, sequence: fold.cursor) }
            do {
                let result = try await SessionJournalRead.read(socketPath: endpoint.socketPath, kinds: AgentSessionFold.journalKinds,
                                                               cursor: fold.cursor > 0 ? cursor : nil)
                apply(result, machine: machine)
            } catch {
                logger.info("agent history: journal read on \(machine, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // A new daemon session (restart) invalidates the cursor.
                generations[machine] = nil
                folds[machine] = nil
            }
        }
    }

    private func apply(_ result: SessionJournalRead.Result, machine: String) {
        var fold = folds[machine] ?? AgentSessionFold(machine: machine)
        if let generation = result.generation, let known = generations[machine], known != generation {
            fold = AgentSessionFold(machine: machine)
        }
        let decoder = JSONDecoder()
        fold.apply(result.records.compactMap { try? decoder.decode(AgentJournalRecord.self, from: $0) })
        folds[machine] = fold
        if let generation = result.generation { generations[machine] = generation }
    }

    /// Every known session, newest activity first, minus hidden ones.
    var sessions: [AgentSession] {
        folds.values.flatMap(\.ordered)
            .filter { session in
                !hiddenSessions.contains(session.qualifiedID) && !hiddenRanges.contains { $0.contains(session.lastActivityAt) }
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func entries() -> [HistoryEntry] {
        sessions.map { session in
            let connected = services.machines.daemons.contains { $0.machineID == session.machine }
            return HistoryEntry(
                id: "agent:\(session.qualifiedID)", kind: .agent, time: session.lastActivityAt,
                title: HistoryAppStrings.agentTitle(provider: session.provider, cwd: session.cwd), detail: session.cwd,
                machineName: session.machine == MachineRegistry.localID ? nil : session.machine,
                isAvailable: connected, payload: .agent(session))
        }
    }

    func session(id: String) -> AgentSession? {
        sessions.first { $0.sessionID == id || $0.qualifiedID == id }
    }

    func hide(since: Date?) {
        hiddenRanges.append((since ?? .distantPast)...Date())
    }

    func hide(_ session: AgentSession) {
        hiddenSessions.insert(session.qualifiedID)
    }
}
