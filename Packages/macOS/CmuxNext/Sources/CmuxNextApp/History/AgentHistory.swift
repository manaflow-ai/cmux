import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Observation
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
    /// Hidden by Clear History or Remove from History (the journal is
    /// append-only), kept in the home session's projection `history.hidden`.
    private(set) var hidden = HiddenHistory()
    private var hiddenRevision: UInt64?
    private var hiddenLoaded = false
    private var observation: Task<Void, Never>?
    static let hiddenSubject = "history.hidden"
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    init(services: AppServices) {
        self.services = services
        let store = services.daemon.store
        observation = Task { [weak self] in
            for await connected in Observations({ if case .connected = store.connectionState { true } else { false } }) where connected {
                self?.loadHidden()
            }
        }
    }

    deinit { observation?.cancel() }

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
            .filter { !hidden.hides($0.qualifiedID, activeAt: $0.lastActivityAt) }
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
        hidden.hide(since: since, now: Date())
        saveHidden()
    }

    func hide(_ session: AgentSession) {
        hidden.hide(entry: session.qualifiedID)
        saveHidden()
    }

    // MARK: Persistence (home session projection)

    private func loadHidden() {
        guard !hiddenLoaded else { return }
        services.daemon.send("history-hidden-load") { [weak self] connection in
            let projection = try await connection.frontendProjection(subject: Self.hiddenSubject)
            let stored = projection.schemaVersion == HiddenHistory.schemaVersion && projection.projection != .null
                ? try? JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(projection.projection)) : nil
            await MainActor.run {
                guard let self else { return }
                self.hiddenLoaded = true
                self.hiddenRevision = projection.projectionRevision
                // Hides made before the load are kept.
                if let stored { self.hidden = stored.merged(with: self.hidden) }
            }
        }
    }

    private func saveHidden() {
        let document = hidden
        let revision = hiddenRevision
        services.daemon.send("history-hidden-save") { [weak self] connection in
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(document))
            do {
                let stored = try await connection.putFrontendProjection(subject: Self.hiddenSubject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: value, expectedRevision: revision)
                await MainActor.run { self?.hiddenRevision = stored.projectionRevision }
            } catch DaemonError.command(_, let message, _) where message.contains("revision conflict") {
                // Another writer: merge both documents, so no clear is lost.
                let current = try await connection.frontendProjection(subject: Self.hiddenSubject)
                let theirs = (try? JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(current.projection))) ?? HiddenHistory()
                let merged = theirs.merged(with: document)
                let mergedValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(merged))
                let stored = try await connection.putFrontendProjection(subject: Self.hiddenSubject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: mergedValue, expectedRevision: current.projectionRevision)
                await MainActor.run {
                    self?.hidden = merged
                    self?.hiddenRevision = stored.projectionRevision
                }
            }
        }
    }
}
