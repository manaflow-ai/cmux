import CmuxAgentReplica
import CmuxAgentWire
import Foundation

@MainActor
final class AgentGUIAskRegistry {
    private struct JournalKey: Hashable {
        let sessionID: AgentSessionID
        let journalID: JournalID
    }

    private struct Record {
        var ask: PendingAsk
        let journalID: JournalID
        let seq: EntrySeq
        let createdAt: Int
    }

    private let clock: () -> Int
    private let injector: any AgentGUITerminalInjecting
    private let publish: (PendingAsk) -> Void
    private var sessions: [AgentSessionID: AgentSessionSnapshot] = [:]
    private var records: [String: Record] = [:]
    private var pendingEntries: [JournalKey: EntrySnapshot] = [:]

    init(
        clock: @escaping () -> Int,
        injector: any AgentGUITerminalInjecting,
        publish: @escaping (PendingAsk) -> Void
    ) {
        self.clock = clock
        self.injector = injector
        self.publish = publish
    }

    var hasPendingExpirations: Bool {
        records.values.contains { record in
            record.ask.state == .active
        }
    }

    func handleSessionSnapshot(_ snapshot: AgentSessionSnapshot) {
        sessions[snapshot.id] = snapshot
        guard snapshot.phase == .needsInput else { return }
        let keys = pendingEntries.keys
            .filter { $0.sessionID == snapshot.id }
            .sorted { $0.journalID.rawValue < $1.journalID.rawValue }
        for key in keys {
            createPendingAskIfNeeded(for: key)
        }
    }

    func removeSession(_ sessionID: AgentSessionID) {
        sessions.removeValue(forKey: sessionID)
        records = records.filter { $0.value.ask.sessionID != sessionID }
        pendingEntries = pendingEntries.filter { $0.key.sessionID != sessionID }
    }

    func handleJournalEvent(_ event: AgentGUIJournalPipelineEvent, sessionID: AgentSessionID) {
        switch event {
        case .appended(let journalID, let entries):
            for entry in entries {
                supersedeActiveAsks(beforeCreatingAskFrom: entry, journalID: journalID, sessionID: sessionID)
                trackPendingAskEntry(entry, journalID: journalID, sessionID: sessionID)
            }
        case .reset(let journalID, _):
            pendingEntries.removeValue(forKey: JournalKey(sessionID: sessionID, journalID: journalID))
        case .replaced:
            break
        }
    }

    func answer(params: GuiAnswerParams) throws -> GuiAnswerResult {
        guard params.choiceIndex >= 0, params.choiceIndex < 9 else {
            throw AgentGUIRPCError.invalidParams
        }
        guard let record = records[params.askID], record.ask.sessionID == params.sessionID else {
            throw AgentGUIRPCError.notFound
        }
        switch record.ask.state {
        case .answered:
            return GuiAnswerResult(answered: true)
        case .expired, .superseded:
            return GuiAnswerResult(answered: false)
        case .active:
            break
        }
        guard params.choiceIndex < record.ask.optionsCount else {
            throw AgentGUIRPCError.invalidParams
        }
        guard let surfaceID = sessions[params.sessionID]?.surfaceID, !surfaceID.isEmpty else {
            throw AgentGUIRPCError.bindingLost
        }
        let digit = String(params.choiceIndex + 1)
        let result = injector.sendInput(surfaceID: surfaceID, text: digit)
        guard result.accepted else {
            throw AgentGUIRPCError.fromInjectionFailure(result)
        }
        transition(params.askID, to: .answered(choice: params.choiceIndex))
        return GuiAnswerResult(answered: true)
    }

    func expire(now: Int? = nil) {
        let current = now ?? clock()
        for (askID, record) in records where record.ask.state == .active {
            guard current - record.createdAt >= AgentGUIConstants.askTimeoutMS else { continue }
            transition(askID, to: .expired)
        }
    }

    private func trackPendingAskEntry(_ entry: EntrySnapshot, journalID: JournalID, sessionID: AgentSessionID) {
        let key = JournalKey(sessionID: sessionID, journalID: journalID)
        if let pending = pendingEntries[key], pending.seq > entry.seq {
            return
        }
        switch entry.content.payload {
        case .question, .permission:
            pendingEntries[key] = entry
        default:
            if let pending = pendingEntries[key], pending.seq < entry.seq {
                pendingEntries.removeValue(forKey: key)
            }
            return
        }
        createPendingAskIfNeeded(for: key)
    }

    private func createPendingAskIfNeeded(for key: JournalKey) {
        guard sessions[key.sessionID]?.phase == .needsInput,
              let entry = pendingEntries[key] else {
            return
        }
        let sessionID = key.sessionID
        let journalID = key.journalID
        let askID = Self.askID(journalID: journalID, seq: entry.seq)
        guard records[askID] == nil else {
            pendingEntries.removeValue(forKey: key)
            return
        }
        let ask: PendingAsk
        switch entry.content.payload {
        case .question(let payload):
            ask = PendingAsk(
                id: askID,
                sessionID: sessionID,
                kind: .question,
                promptSummary: payload.prompt,
                optionsCount: payload.options.count,
                state: payload.answeredChoice.map { .answered(choice: $0) } ?? .active
            )
        case .permission(let payload):
            let summary = payload.detail.isEmpty ? payload.toolName : payload.detail
            ask = PendingAsk(
                id: askID,
                sessionID: sessionID,
                kind: .permission,
                promptSummary: summary,
                optionsCount: payload.options.count,
                state: .active
            )
        default:
            return
        }
        records[askID] = Record(ask: ask, journalID: journalID, seq: entry.seq, createdAt: clock())
        pendingEntries.removeValue(forKey: key)
        publish(ask)
    }

    private func supersedeActiveAsks(beforeCreatingAskFrom entry: EntrySnapshot, journalID: JournalID, sessionID: AgentSessionID) {
        for (askID, record) in records {
            guard record.ask.sessionID == sessionID,
                  record.journalID == journalID,
                  record.ask.state == .active,
                  record.seq.rawValue < entry.seq.rawValue else {
                continue
            }
            transition(askID, to: .superseded)
        }
    }

    private func transition(_ askID: String, to state: PendingAskState) {
        guard var record = records[askID] else { return }
        let current = record.ask
        let next = PendingAsk(
            id: current.id,
            sessionID: current.sessionID,
            kind: current.kind,
            promptSummary: current.promptSummary,
            optionsCount: current.optionsCount,
            state: state
        )
        record.ask = next
        records[askID] = record
        publish(next)
    }

    static func askID(journalID: JournalID, seq: EntrySeq) -> String {
        "\(journalID.rawValue):\(seq.rawValue)"
    }
}
