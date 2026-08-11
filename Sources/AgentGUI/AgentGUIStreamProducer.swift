import CmuxAgentReplica
import CmuxAgentWire
import Foundation

/// Publishes best-effort terminal previews while a subscribed agent turn is active.
@MainActor
final class AgentGUIStreamProducer {
    struct Context: Equatable {
        let journalID: JournalID
        let afterSeq: EntrySeq
    }

    private struct ActiveTurn {
        let surfaceID: UUID
        let agentKind: AgentKind
        var settled = false
        var lastEmitted: String?
        var revision = 0
    }

    private let extractor = AgentGUIProseScreenExtractor()
    private let publish: @MainActor (AgentSessionID, GuiStreamTickEvent) -> Void
    private let snapshot: @MainActor (UUID) -> [String]?
    private let hasSubscribers: @MainActor (AgentSessionID) -> Bool
    private let context: @MainActor (AgentSessionID) -> Context?
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var turns: [AgentSessionID: ActiveTurn] = [:]
    private var tasks: [AgentSessionID: Task<Void, Never>] = [:]

    init(
        publish: @escaping @MainActor (AgentSessionID, GuiStreamTickEvent) -> Void,
        snapshot: @escaping @MainActor (UUID) -> [String]?,
        hasSubscribers: @escaping @MainActor (AgentSessionID) -> Bool,
        context: @escaping @MainActor (AgentSessionID) -> Context?,
        pollInterval: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.publish = publish
        self.snapshot = snapshot
        self.hasSubscribers = hasSubscribers
        self.context = context
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    func turnStarted(sessionID: AgentSessionID, surfaceID: UUID, agentKind: AgentKind) {
        turns[sessionID] = ActiveTurn(surfaceID: surfaceID, agentKind: agentKind)
        guard tasks[sessionID] == nil else { return }
        tasks[sessionID] = Task { [weak self] in
            await self?.runLoop(sessionID: sessionID)
        }
    }

    func authoritativeProseArrived(sessionID: AgentSessionID) {
        guard turns[sessionID] != nil else { return }
        turns[sessionID]?.settled = true
        clearPreview(sessionID: sessionID)
    }

    func journalEventArrived(
        _ event: AgentGUIJournalPipelineEvent,
        sessionID: AgentSessionID,
        window: AgentGUIJournalWindow?
    ) {
        guard event.containsAgentProse(in: window) else { return }
        authoritativeProseArrived(sessionID: sessionID)
    }

    func turnEnded(sessionID: AgentSessionID) {
        tasks.removeValue(forKey: sessionID)?.cancel()
        guard turns.removeValue(forKey: sessionID) != nil else { return }
        clearPreview(sessionID: sessionID)
    }

    func stopAll() {
        for sessionID in Array(turns.keys) { turnEnded(sessionID: sessionID) }
    }

    func emitPreviewIfChanged(sessionID: AgentSessionID) {
        guard var turn = turns[sessionID], !turn.settled,
              hasSubscribers(sessionID),
              let streamContext = context(sessionID),
              let lines = snapshot(turn.surfaceID),
              let prose = extractor.extract(lines: lines, agentKind: turn.agentKind),
              prose != turn.lastEmitted else { return }
        turn.revision += 1
        turn.lastEmitted = prose
        turns[sessionID] = turn
        publish(sessionID, GuiStreamTickEvent(
            journalID: streamContext.journalID,
            afterSeq: streamContext.afterSeq,
            textTail: prose,
            revision: turn.revision
        ))
    }

    private func runLoop(sessionID: AgentSessionID) async {
        while !Task.isCancelled {
            emitPreviewIfChanged(sessionID: sessionID)
            await sleep(pollInterval)
        }
    }

    private func clearPreview(sessionID: AgentSessionID) {
        guard let streamContext = context(sessionID) else { return }
        let revision = (turns[sessionID]?.revision ?? 0) + 1
        publish(sessionID, GuiStreamTickEvent(
            journalID: streamContext.journalID,
            afterSeq: streamContext.afterSeq,
            textTail: "",
            revision: revision
        ))
    }
}

private extension AgentGUIJournalPipelineEvent {
    func containsAgentProse(in window: AgentGUIJournalWindow?) -> Bool {
        switch self {
        case .reset(let journalID, _):
            guard window?.journalID == journalID else { return false }
            return window?.entriesBySeq.values.contains { $0.kind == .agentProse } == true
        case .appended(_, let entries):
            return entries.contains { $0.kind == .agentProse }
        case .replaced(_, let entry):
            return entry.kind == .agentProse
        }
    }
}
