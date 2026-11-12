import CmuxNextDaemon
public import CmuxNextHistory
import Foundation

/// One machine's agent sessions as the app last read them, and the two reads that bring them up to date.
///
/// A daemon with `history-agent-sessions-v1` lists each session whole (`history.entries.list`). It keeps the
/// fold of its journal with its cursor, so a session whose records journal retention deleted is still in its
/// list, and the app never folds that daemon's journal. While that fold is behind, the daemon's list is not
/// complete (`isComplete`), and it takes no session away. A daemon without the capability is older than
/// retention: its journal has every record, and the app folds it from the first one
/// (`session.journal.subscribe`), then only the records after its cursor.
public struct MachineAgentSessions: Sendable {
    public let machine: String
    /// The sessions of a daemon that lists them; nil before its first answer and for an older daemon.
    public private(set) var listed: [AgentSession]?
    /// The fold of an older daemon's journal.
    public private(set) var fold: AgentSessionFold
    /// That journal's session id (the cursor generation).
    private var generation: String?

    public init(machine: String) {
        self.machine = machine
        fold = AgentSessionFold(machine: machine)
    }

    /// The sessions of a journal fold.
    public init(fold: AgentSessionFold) {
        machine = fold.machine
        self.fold = fold
    }

    /// The sessions of a daemon's list.
    public init(machine: String, listed: [AgentSession]) {
        self.init(machine: machine)
        self.listed = listed
    }

    /// Newest activity first.
    public var sessions: [AgentSession] {
        listed?.sorted { ($0.lastActivityAt, $0.sessionID) > ($1.lastActivityAt, $1.sessionID) } ?? fold.ordered
    }

    /// Takes the daemon's list. A daemon that does not answer keeps what it answered before: an empty list is
    /// only ever the daemon's own answer.
    public mutating func read(list daemon: DaemonHistoryClient) async {
        let machine = machine
        guard let list = await DaemonHistoryClient.retrying({ try await daemon.agentSessions(machine: machine) }) else { return }
        take(listed: list.sessions, complete: list.isComplete)
    }

    /// False while the daemon's list is not complete (`pending_kinds` names `agent`: its fold of the journal
    /// is behind): a session that `sessions` does not have can still exist.
    public private(set) var isComplete = true

    /// The daemon's whole list replaces every session read before, a journal fold of the same daemon's older
    /// build too. A list that is not complete (`complete` false) takes no session away: the daemon's fold
    /// goes from the oldest record up, so that list is short, and a session read before that it does not have
    /// stays as it was until the whole list comes.
    public mutating func take(listed sessions: [AgentSession], complete: Bool = true) {
        if complete {
            listed = sessions
        } else {
            let read = Set(sessions.map(\.qualifiedID))
            listed = sessions + self.sessions.filter { !read.contains($0.qualifiedID) }
        }
        isComplete = complete
        fold = AgentSessionFold(machine: machine)
        generation = nil
    }

    /// Folds an older daemon's journal: every record at the first read, then the records after the cursor.
    /// A failed read (a restarted daemon refuses the cursor of its last session) drops the fold, so the next
    /// read starts at the first record again.
    public mutating func read(journal socketPath: String) async throws {
        let cursor = generation.map { (generation: $0, sequence: fold.cursor) }
        do {
            let result = try await SessionJournalRead.shared.read(socketPath: socketPath, kinds: AgentSessionFold.journalKinds,
                                                                  cursor: fold.cursor > 0 ? cursor : nil)
            if let read = result.generation, let known = generation, known != read { fold = AgentSessionFold(machine: machine) }
            let decoder = JSONDecoder()
            fold.apply(result.records.compactMap { try? decoder.decode(AgentJournalRecord.self, from: $0) })
            if let read = result.generation { generation = read }
            listed = nil
            isComplete = true
        } catch {
            fold = AgentSessionFold(machine: machine)
            generation = nil
            throw error
        }
    }
}
