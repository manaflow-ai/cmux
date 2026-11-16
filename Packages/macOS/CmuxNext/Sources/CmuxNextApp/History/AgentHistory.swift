import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import os

/// Agent sessions from each connected machine's session journal
/// (plans/cmux-next/history.md 2, `agent`) for the vault, the agents palette
/// page and resume by id: every machine, with each session's tab and
/// terminal, which the local daemon's merged history (`history.entries.list`)
/// does not carry. The History page reads agents from the daemon. This keeps
/// one `AgentSessionFold` per machine and reads only the records after its
/// cursor when a caller asks (`refresh`), so nothing polls.
final class AgentHistory {
    private unowned let services: AppServices
    var folds: [String: AgentSessionFold] = [:] // per machine (tests fill one)
    private var generations: [String: String] = [:]
    private var refreshing: Task<Void, Never>?
    /// Hidden by Clear History or Remove from History (the journal is
    /// append-only); the daemon history module writes the hides.
    let hidden: HiddenHistoryStore
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    init(services: AppServices, hidden: HiddenHistoryStore) {
        self.services = services
        self.hidden = hidden
    }

    /// Reads new agent records from every connected machine that serves the
    /// session journal. Concurrent calls share one read.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        // The owner's daemons are read before the first suspension, so a weak capture is enough.
        let task = Task { [weak self] in _ = await self?.readAll() }
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
                let result = try await SessionJournalRead.shared.read(socketPath: endpoint.socketPath, kinds: AgentSessionFold.journalKinds,
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
            .filter { !hidden.document.hides($0.qualifiedID, activeAt: $0.lastActivityAt, kind: "agent") }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func session(id: String) -> AgentSession? {
        sessions.first { $0.sessionID == id || $0.qualifiedID == id }
    }
}
