import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// Main-actor registry of chat-capable agent sessions, built from agent
/// hook events and the on-disk hook session stores.
@MainActor
final class AgentChatSessionRegistry {
    private var records: [String: AgentChatSessionRecord] = [:]
    private var liveSessionIDBySurfaceID: [String: String] = [:]
    private let hookStore: AgentChatHookSessionStore

    /// Called after a record mutation with the previous value (nil for a
    /// brand-new record), so the owner derives state/descriptor deltas in
    /// one place instead of hand-maintained flags.
    var onRecordChanged: ((AgentChatSessionRecord, _ previous: AgentChatSessionRecord?) -> Void)?

    /// Per-session timestamp of the last hook-store file consult, bounding
    /// main-actor disk reads during tool storms.
    private var hookStoreConsultedAt: [String: Date] = [:]

    /// Per-session monotonic revision counter. Every stored record carries the
    /// current value so clients reconcile best-effort pushes against
    /// authoritative pulls: apply a push only when its version exceeds the last
    /// applied, replace wholesale on a snapshot pull. A counter (not a hash)
    /// guarantees strict monotonicity even when a change reverts a field.
    private var versionBySessionID: [String: Int] = [:]

    /// Stamps the next monotonic version onto a record before it is stored.
    /// All write paths route through this so no externally visible change ever
    /// ships with a stale or unchanged version.
    private func stampVersion(_ record: inout AgentChatSessionRecord) {
        let next = (versionBySessionID[record.sessionID] ?? 0) + 1
        versionBySessionID[record.sessionID] = next
        record.version = next
    }

    /// Per-session process-exit watchers, keyed by session id, each tagged with
    /// the pid it watches. A `DispatchSourceProcess` (`.exit`) fires exactly
    /// when the agent process dies (crash, kill, closed terminal), so the
    /// session flips to `.ended` deterministically without a `SessionEnd` hook
    /// and without polling `kill(pid,0)` on every read. `DispatchSource` is an
    /// event source, not a timer, and is cancellable.
    private var exitWatchers: [String: (pid: Int, source: DispatchSourceProcess)] = [:]

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
        return records.values
            .filter { workspaceID == nil || $0.workspaceID == workspaceID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Reconciles the session's exit watcher with its current pid. Called from
    /// every record-store path, so a watcher exists exactly while a session has
    /// a live pid and is cancelled when the pid changes, clears, or the session
    /// ends. Idempotent: a no-op when already watching the right pid.
    ///
    /// A process that is already gone at registration (the app was off while it
    /// died) would never produce an `.exit` event, so that case ends the
    /// session on a fresh main-actor turn rather than registering a watcher.
    private func syncProcessExitWatch(for record: AgentChatSessionRecord) {
        let sessionID = record.sessionID
        if let existing = exitWatchers[sessionID], existing.pid == record.pid {
            return
        }
        exitWatchers[sessionID]?.source.cancel()
        exitWatchers[sessionID] = nil
        guard record.state != .ended, let pid = record.pid else { return }
        // ESRCH means the process is already gone; EPERM means it exists but is
        // not signalable, which still counts as alive.
        if kill(pid_t(pid), 0) != 0, errno == ESRCH {
            Task { @MainActor [weak self] in self?.handleProcessExit(sessionID: sessionID, pid: pid) }
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(pid),
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleProcessExit(sessionID: sessionID, pid: pid) }
        }
        exitWatchers[sessionID] = (pid: pid, source: source)
        source.resume()
    }

    /// Flips a session to `.ended` because its agent process exited. Ignores a
    /// stale fire: the session may have resumed under a new pid (`claude
    /// --resume`), and the predecessor's exit must not end the live session.
    /// `ended` is retained (the GUI stays shown, the input bar disables); only
    /// the watcher is torn down.
    private func handleProcessExit(sessionID: String, pid: Int) {
        guard let record = records[sessionID], record.pid == pid, record.state != .ended else {
            return
        }
        update(sessionID: sessionID) { $0.state = .ended }
    }

    /// One session's record.
    ///
    /// - Parameter sessionID: Raw (unprefixed) session id.
    /// - Returns: The record, or `nil` when unknown.
    func record(sessionID: String) -> AgentChatSessionRecord? {
        records[sessionID]
    }

    /// The current live session bound to a terminal surface, if any.
    ///
    /// - Parameter surfaceID: Terminal surface UUID string.
    /// - Returns: A non-ended record bound to the surface, or `nil`.
    func liveSession(surfaceID: String) -> AgentChatSessionRecord? {
        while let sessionID = liveSessionIDBySurfaceID[surfaceID] {
            guard let record = records[sessionID],
                  record.surfaceID == surfaceID,
                  record.state != .ended else {
                liveSessionIDBySurfaceID.removeValue(forKey: surfaceID)
                return nil
            }
            if let pid = record.pid, processIsDead(pid) {
                update(sessionID: sessionID) { $0.state = .ended }
                continue
            }
            return record
        }
        return nil
    }

    /// Re-reads the hook store for one session and adopts its bindings,
    /// for callers that just failed to resolve the recorded terminal (an
    /// app relaunch regenerates panel UUIDs; the store is rewritten by
    /// every hook event and is the authority).
    ///
    /// - Parameter sessionID: The session to refresh.
    /// - Returns: The refreshed record, or `nil` when unknown.
    @discardableResult
    func refreshBindingsFromHookStore(sessionID: String) -> AgentChatSessionRecord? {
        guard let record = records[sessionID] else { return nil }
        guard let entry = hookStore.entry(agentSource: record.agentKind.sourceName, sessionID: sessionID) else {
            return record
        }
        update(sessionID: sessionID) { $0.adoptBindings(from: entry, includingPID: false) }
        return records[sessionID]
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
        stampVersion(&record)
        records[sessionID] = record
        syncProcessExitWatch(for: record)
        updateLiveSessionIndex(previous: previous, current: record)
        onRecordChanged?(record, previous)
    }

    /// A transcript tail can observe a completed assistant turn even when
    /// the agent hook stream never emits Stop (Claude weekly-limit replies
    /// do this). Use that transcript fact only to clear an active working
    /// state; later hooks remain authoritative and can move the session
    /// back to working or needs-input.
    func noteAssistantTurnCompleted(sessionID: String, at timestamp: Date) {
        update(sessionID: sessionID) { record in
            guard case .working = record.state else { return }
            record.state = .idle
            if timestamp > record.lastActivityAt {
                record.lastActivityAt = timestamp
            }
        }
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
                var record = AgentChatSessionRecord(
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
                stampVersion(&record)
                records[entry.sessionID] = record
                syncProcessExitWatch(for: record)
                updateLiveSessionIndex(previous: nil, current: record)
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
            // sweep re-end the live session. The event's ppid IS the new
            // agent process (hooks are spawned by it); the hook store
            // cannot be trusted here because the CLI posts this event
            // BEFORE rewriting the store, so a same-event consult would
            // re-adopt the dead pid. Suppress the consult for now.
            record.pid = event.ppid
            hookStoreConsultedAt[sessionID] = event.receivedAt
        }
        // The hook store is a whole-file JSON read on the main actor;
        // consult it at most every 30s per session while fields are still
        // missing (pid can legitimately stay absent), not on every
        // pre/postToolUse during a tool storm. Consult BEFORE applying the
        // event's own fields: the store lags the event by one write, so
        // the live event must win any disagreement.
        let needsHookStore = record.surfaceID == nil || record.transcriptPath == nil || record.pid == nil
        let lastConsult = hookStoreConsultedAt[sessionID]
        if needsHookStore,
           lastConsult.map({ event.receivedAt.timeIntervalSince($0) > 30 }) ?? true {
            hookStoreConsultedAt[sessionID] = event.receivedAt
            if let entry = hookStore.entry(agentSource: event.source, sessionID: sessionID) {
                // Adopt the store pid only when the record has none: the
                // record's pid comes from the event's own ppid and is
                // fresher than a store entry that may predate a resume.
                record.adoptBindings(from: entry, includingPID: record.pid == nil)
            }
        }
        if let workspaceID = event.workspaceId, !workspaceID.isEmpty {
            record.workspaceID = workspaceID
        }
        if let cwd = event.cwd, !cwd.isEmpty {
            record.workingDirectory = cwd
        }
        record.lastActivityAt = event.receivedAt

        let previous = records[sessionID]
        record.state = Self.nextState(previous: record.state, event: event)
        stampVersion(&record)
        records[sessionID] = record
        syncProcessExitWatch(for: record)
        updateLiveSessionIndex(previous: previous, current: record)
        onRecordChanged?(record, previous)
        return record
    }

    private func updateLiveSessionIndex(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) {
        let previousSurfaceID = Self.liveSurfaceID(previous)
        let currentSurfaceID = Self.liveSurfaceID(current)
        if let previousSurfaceID,
           previousSurfaceID != currentSurfaceID,
           liveSessionIDBySurfaceID[previousSurfaceID] == previous?.sessionID {
            liveSessionIDBySurfaceID.removeValue(forKey: previousSurfaceID)
            rebuildLiveSessionIndex(surfaceID: previousSurfaceID)
        }
        guard let currentSurfaceID else { return }
        guard let indexedSessionID = liveSessionIDBySurfaceID[currentSurfaceID],
              let indexed = records[indexedSessionID],
              indexed.surfaceID == currentSurfaceID,
              indexed.state != .ended else {
            liveSessionIDBySurfaceID[currentSurfaceID] = current.sessionID
            return
        }
        if indexed.sessionID == current.sessionID || current.lastActivityAt >= indexed.lastActivityAt {
            liveSessionIDBySurfaceID[currentSurfaceID] = current.sessionID
        }
    }

    private func rebuildLiveSessionIndex(surfaceID: String?) {
        guard let surfaceID else { return }
        if let newest = records.values
            .filter({ $0.surfaceID == surfaceID && $0.state != .ended })
            .max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
            liveSessionIDBySurfaceID[surfaceID] = newest.sessionID
        } else {
            liveSessionIDBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    private static func liveSurfaceID(_ record: AgentChatSessionRecord?) -> String? {
        guard let record, record.state != .ended else {
            return nil
        }
        return record.surfaceID
    }

    private func processIsDead(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) != 0 && errno == ESRCH
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
