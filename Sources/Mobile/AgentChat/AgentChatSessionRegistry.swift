import CMUXWorkstream
import CmuxAgentChat
import Foundation

/// Main-actor registry of chat-capable agent sessions, built from agent
/// hook events and the on-disk hook session stores.
@MainActor
final class AgentChatSessionRegistry {
    private var records: [String: AgentChatSessionRecord] = [:]
    private let hookStore: AgentChatHookSessionStore

    /// Called after a record mutation with the previous value (nil for a
    /// brand-new record), so the owner derives state/descriptor deltas in
    /// one place instead of hand-maintained flags.
    var onRecordChanged: ((AgentChatSessionRecord, _ previous: AgentChatSessionRecord?) -> Void)?

    /// Per-session timestamp of the last hook-store file consult, bounding
    /// main-actor disk reads during tool storms.
    private var hookStoreConsultedAt: [String: Date] = [:]

    /// Creates a registry.
    ///
    /// - Parameter hookStore: Reader for the per-agent hook session stores.
    init(hookStore: AgentChatHookSessionStore = AgentChatHookSessionStore()) {
        self.hookStore = hookStore
    }

    /// All known sessions, optionally restricted to one workspace, most
    /// recent activity first.
    ///
    /// - Parameter workspaceID: Workspace UUID string filter, or `nil`.
    /// - Returns: Matching records.
    func sessions(workspaceID: String?) -> [AgentChatSessionRecord] {
        sweepDeadProcesses()
        return records.values
            .filter { workspaceID == nil || $0.workspaceID == workspaceID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Marks sessions whose agent process died without a SessionEnd hook
    /// (crash, kill, closed terminal) as ended, so a missing Stop hook
    /// cannot wedge a session in "working" forever.
    private func sweepDeadProcesses() {
        for (sessionID, record) in records {
            guard record.state != .ended, let pid = record.pid else { continue }
            // ESRCH means the process is gone; EPERM means it exists but is
            // not signalable, which still counts as alive.
            if kill(pid_t(pid), 0) != 0, errno == ESRCH {
                update(sessionID: sessionID) { $0.state = .ended }
            }
        }
    }

    /// One session's record.
    ///
    /// - Parameter sessionID: Raw (unprefixed) session id.
    /// - Returns: The record, or `nil` when unknown.
    func record(sessionID: String) -> AgentChatSessionRecord? {
        records[sessionID]
    }

    /// Applies a mutation to a record and notifies the change callback
    /// with the previous value.
    ///
    /// - Parameters:
    ///   - sessionID: The session to mutate.
    ///   - mutate: The in-place mutation.
    func update(
        sessionID: String,
        mutate: (inout AgentChatSessionRecord) -> Void
    ) {
        guard let previous = records[sessionID] else { return }
        var record = previous
        mutate(&record)
        records[sessionID] = record
        onRecordChanged?(record, previous)
    }

    /// Seeds the registry from the on-disk hook stores so sessions started
    /// before app launch are listable immediately. Dead processes register
    /// as ended.
    ///
    /// - Parameter agentSources: The agent store files to read.
    func seedFromHookStores(agentSources: [String] = ["claude", "codex"]) {
        for source in agentSources {
            let kind = ChatAgentKind(source: source)
            for entry in hookStore.entries(agentSource: source) {
                guard records[entry.sessionID] == nil else { continue }
                let alive = entry.pid.map { kill(pid_t($0), 0) == 0 } ?? false
                records[entry.sessionID] = AgentChatSessionRecord(
                    sessionID: entry.sessionID,
                    agentKind: kind,
                    workspaceID: entry.workspaceID,
                    surfaceID: entry.surfaceID,
                    workingDirectory: entry.workingDirectory,
                    transcriptPath: entry.transcriptPath,
                    state: alive ? .idle : .ended,
                    lastActivityAt: entry.updatedAt ?? .distantPast,
                    title: nil,
                    pid: entry.pid
                )
            }
        }
    }

    /// Ingests one hook event: creates or refreshes the session record and
    /// derives the live state transition.
    ///
    /// - Parameter event: The hook event as published by the agent CLI.
    /// - Returns: The up-to-date record.
    @discardableResult
    func noteHookEvent(_ event: WorkstreamEvent) -> AgentChatSessionRecord {
        let sessionID = Self.normalizedSessionID(event.sessionId, source: event.source)
        let kind = ChatAgentKind(source: event.source)
        var record = records[sessionID] ?? AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: kind,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: event.receivedAt,
            title: nil,
            pid: nil
        )
        if event.hookEventName == .sessionStart {
            // A resumed session (claude --resume reuses session ids) runs
            // under a NEW process; the old pid would make the liveness
            // sweep re-end the live session. Drop it and re-consult.
            record.pid = nil
            hookStoreConsultedAt[sessionID] = nil
        }
        if let workspaceID = event.workspaceId, !workspaceID.isEmpty {
            record.workspaceID = workspaceID
        }
        if let cwd = event.cwd, !cwd.isEmpty {
            record.workingDirectory = cwd
        }
        // The hook store is a whole-file JSON read on the main actor;
        // consult it at most every 30s per session while fields are still
        // missing (pid can legitimately stay absent), not on every
        // pre/postToolUse during a tool storm.
        let needsHookStore = record.surfaceID == nil || record.transcriptPath == nil || record.pid == nil
        let lastConsult = hookStoreConsultedAt[sessionID]
        if needsHookStore,
           lastConsult.map({ event.receivedAt.timeIntervalSince($0) > 30 }) ?? true {
            hookStoreConsultedAt[sessionID] = event.receivedAt
            if let entry = hookStore.entry(agentSource: event.source, sessionID: sessionID) {
                record.surfaceID = record.surfaceID ?? entry.surfaceID
                record.workspaceID = record.workspaceID ?? entry.workspaceID
                record.transcriptPath = record.transcriptPath ?? entry.transcriptPath
                record.workingDirectory = record.workingDirectory ?? entry.workingDirectory
                record.pid = record.pid ?? entry.pid
            }
        }
        record.lastActivityAt = event.receivedAt

        let previous = records[sessionID]
        record.state = Self.nextState(previous: record.state, event: event)
        records[sessionID] = record
        onRecordChanged?(record, previous)
        return record
    }

    /// Strips an agent-name prefix from prefixed workstream ids
    /// (`claude-<uuid>`); raw hook ids pass through.
    private static func normalizedSessionID(_ id: String, source: String) -> String {
        let prefix = "\(source)-"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    private static func nextState(
        previous: ChatAgentState,
        event: WorkstreamEvent
    ) -> ChatAgentState {
        switch event.hookEventName {
        case .sessionStart:
            return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse, .todoWrite:
            if case .working = previous { return previous }
            return .working(since: event.receivedAt)
        case .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            if case .needsInput = previous { return previous }
            return .needsInput(since: event.receivedAt)
        case .stop:
            return .idle
        case .subagentStop:
            // A Task subagent finishing says nothing about the parent
            // session's activity; keep the current state.
            return previous
        case .sessionEnd:
            return .ended
        }
    }
}
