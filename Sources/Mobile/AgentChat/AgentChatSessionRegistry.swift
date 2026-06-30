import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// A coding-agent session discovered by observing the process table, with no
/// dependency on hooks firing. Identity (and, for codex, the transcript path)
/// comes from the agent's own argv or open transcript file, so a session
/// launched through any indirection (a subrouter, a wrapper) is still found.
nonisolated struct ObservedAgentSession: Sendable {
    let sessionID: String
    let agentKind: ChatAgentKind
    let surfaceID: String
    let workspaceID: String?
    let pid: Int
    let transcriptPath: String?
}

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

    /// Observe-floor liveness: the pid of a live agent process matching `kind`
    /// anywhere under `surfaceID`'s process tree, or nil if none.
    ///
    /// A launcher or intermediate process (a subrouter like `sr`, a `node`
    /// shim) is NOT the agent; the real agent binary (e.g. `codex`, `claude`)
    /// appears deeper in the tree. So liveness must be judged from the whole
    /// process tree under the surface, never from a single recorded pid that may
    /// be a launcher. Nonisolated and snapshot-based so it runs off the main
    /// actor; callers hop back to the main actor to apply the result. The
    /// classifier matches by process basename, so only the real agent binary
    /// matches (a `node …/codex` shim is named `node` and does not).
    private nonisolated static func liveAgentPID(surfaceID: String, kind: ChatAgentKind) -> Int? {
        guard let surfaceUUID = UUID(uuidString: surfaceID) else { return nil }
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
        let rootPIDs = snapshot.pids(forCMUXSurfaceID: surfaceUUID)
        guard !rootPIDs.isEmpty else { return nil }
        let wantedID = kind.sourceName
        for pid in snapshot.expandedPIDs(rootPIDs: rootPIDs).sorted() {
            guard let info = snapshot.process(pid: pid),
                  let def = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                      processName: info.name,
                      processPath: info.path,
                      arguments: [],
                      environment: [:]
                  ),
                  def.id == wantedID else { continue }
            return pid
        }
        return nil
    }

    // MARK: Observe-floor detection (process tree)

    /// Off-main scan + main-actor apply: discover live codex/claude sessions by
    /// observing the process table, with no dependency on hooks firing. Resolves
    /// identity from the agent's own state (codex: the rollout file it holds
    /// open; claude: its `--session-id`/`--resume` argv), so a session launched
    /// through any indirection (a subrouter, a wrapper) is still found and bound.
    /// Throttled; safe to call coarsely (e.g. on the iOS list pull). The snapshot
    /// is captured off the main actor.
    private var observeThrottle: Date?
    func observeAgentProcesses() async {
        let now = Date()
        if let last = observeThrottle, now.timeIntervalSince(last) < 2.0 { return }
        observeThrottle = now
        let observed = await Task.detached { Self.scanObservedAgentSessions() }.value
        applyObservedSessions(observed)
    }

    /// Folds detections in: create a record for any session not already known
    /// (state `.idle`, from cmux's own observation), and backfill a missing
    /// binding (surface / workspace / transcript / pid) on an existing one.
    /// Observation only ADDS presence and bindings; it never downgrades
    /// hook-derived state.
    private func applyObservedSessions(_ observed: [ObservedAgentSession]) {
        let now = Date()
        for session in observed {
            #if DEBUG
            cmuxDebugLog(
                "agentChat.detect session=\(session.sessionID.prefix(8)) kind=\(session.agentKind.sourceName) "
                + "surface=\(session.surfaceID.prefix(8)) pid=\(session.pid) "
                + "transcript=\(session.transcriptPath != nil ? "fd" : "argv-only") "
                + "\(records[session.sessionID] == nil ? "new" : "bind-existing")"
            )
            #endif
            if records[session.sessionID] == nil {
                var record = AgentChatSessionRecord(
                    sessionID: session.sessionID,
                    agentKind: session.agentKind,
                    workspaceID: session.workspaceID,
                    surfaceID: session.surfaceID,
                    workingDirectory: nil,
                    transcriptPath: session.transcriptPath,
                    state: .idle,
                    lastActivityAt: now,
                    title: nil,
                    pid: session.pid
                )
                stampVersion(&record)
                records[session.sessionID] = record
                syncProcessExitWatch(for: record)
                updateLiveSessionIndex(previous: nil, current: record)
                onRecordChanged?(record, nil)
            } else {
                update(sessionID: session.sessionID) { rec in
                    if rec.surfaceID == nil { rec.surfaceID = session.surfaceID }
                    if rec.workspaceID == nil { rec.workspaceID = session.workspaceID }
                    if rec.transcriptPath == nil { rec.transcriptPath = session.transcriptPath }
                    if rec.pid == nil { rec.pid = session.pid }
                }
            }
        }
    }

    /// Off-main: one entry per distinct live codex/claude session under any cmux
    /// surface, identity resolved without hooks.
    private nonisolated static func scanObservedAgentSessions() -> [ObservedAgentSession] {
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
        var result: [ObservedAgentSession] = []
        var seen = Set<String>()
        for process in snapshot.cmuxScopedProcesses() {
            guard let surfaceID = process.cmuxSurfaceID,
                  let def = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                      processName: process.name,
                      processPath: process.path,
                      arguments: [],
                      environment: [:]
                  ),
                  def.id == "codex" || def.id == "claude" else { continue }
            var sessionID: String?
            var transcriptPath: String?
            if def.id == "codex", let rollout = openCodexRolloutPath(pid: process.pid) {
                transcriptPath = rollout
                sessionID = firstUUIDLike(in: (rollout as NSString).lastPathComponent)
            }
            if sessionID == nil,
               let argv = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process.pid)?.arguments {
                sessionID = sessionIDFromArguments(argv)
            }
            guard let resolved = sessionID, !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            result.append(ObservedAgentSession(
                sessionID: resolved,
                agentKind: ChatAgentKind(source: def.id),
                surfaceID: surfaceID.uuidString,
                workspaceID: process.cmuxWorkspaceID?.uuidString,
                pid: process.pid,
                transcriptPath: transcriptPath
            ))
        }
        return result
    }

    /// libproc: the path of a `~/.codex/sessions/**/rollout-*.jsonl` the process
    /// holds open (codex keeps its rollout open for writing), or nil.
    private nonisolated static func openCodexRolloutPath(pid: Int) -> String? {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return nil }
        let actual = Int(used) / MemoryLayout<proc_fdinfo>.stride
        for index in 0..<min(actual, fds.count) {
            guard fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fds[index].proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") {
                return path
            }
        }
        return nil
    }

    /// Extracts a session id from an agent's argv (`--session-id <id>`,
    /// `--session-id=<id>`, `--resume <id>`, `--resume=<id>`).
    private nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--session-id" || arg == "--resume", index + 1 < arguments.count,
               let id = firstUUIDLike(in: arguments[index + 1]) {
                return id
            }
            if arg.hasPrefix("--session-id="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--session-id=".count))) {
                return id
            }
            if arg.hasPrefix("--resume="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--resume=".count))) {
                return id
            }
            index += 1
        }
        return nil
    }

    private nonisolated static let uuidLikeRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    /// The first UUID-shaped substring (matches both standard UUIDs and codex's
    /// UUIDv7 rollout ids), or nil.
    private nonisolated static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else { return nil }
        return String(string[matchRange])
    }

    /// The watched agent process exited. Before ending the session, verify
    /// against the surface's process tree off-main: the dead pid may be a
    /// launcher/intermediate (subrouter, `node` shim) while the real agent still
    /// runs, in which case re-bind to the live agent pid instead of ending.
    /// Ignores a stale fire (the session may have resumed under a new pid;
    /// `claude --resume`). `ended` is retained (the GUI stays shown, the input
    /// bar disables); only the watcher is torn down.
    private func handleProcessExit(sessionID: String, pid: Int) {
        guard let record = records[sessionID], record.pid == pid, record.state != .ended else {
            return
        }
        guard let surfaceID = record.surfaceID else {
            update(sessionID: sessionID) { $0.state = .ended }
            return
        }
        let kind = record.agentKind
        Task.detached { [weak self] in
            let livePID = Self.liveAgentPID(surfaceID: surfaceID, kind: kind)
            await MainActor.run { [weak self] in
                guard let self,
                      let current = self.records[sessionID],
                      current.pid == pid,
                      current.state != .ended else { return }
                if let livePID, livePID != pid {
                    // Real agent still alive under the surface: re-bind to it
                    // (this re-arms the exit watcher on the real agent pid).
                    self.update(sessionID: sessionID) { $0.pid = livePID }
                } else {
                    self.update(sessionID: sessionID) { $0.state = .ended }
                }
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
                // The recorded pid is dead, but it may be a launcher while the
                // real agent still runs under the surface (subrouter / shim).
                // Defer to the tree-aware check (re-bind or end off-main); keep
                // showing the session for now so a live agent is never hidden.
                handleProcessExit(sessionID: sessionID, pid: pid)
                return record
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
    func refreshBindingsFromHookStore(sessionID: String) async -> AgentChatSessionRecord? {
        guard let record = records[sessionID] else { return nil }
        let store = hookStore
        let source = record.agentKind.sourceName
        // Whole-file JSON read+parse off the main actor.
        let entry = await Task.detached(priority: .utility) {
            store.entry(agentSource: source, sessionID: sessionID)
        }.value
        guard let entry else { return records[sessionID] }
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
        #if DEBUG
        if previous.state != record.state {
            cmuxDebugLog(
                "agentChat.state session=\(sessionID.prefix(8)) "
                + "\(Self.stateLabel(previous.state))->\(Self.stateLabel(record.state)) v\(record.version)"
            )
        }
        #endif
        syncProcessExitWatch(for: record)
        updateLiveSessionIndex(previous: previous, current: record)
        onRecordChanged?(record, previous)
    }

    #if DEBUG
    /// Compact state label for the debug trace (`idle`/`working`/`needsInput`/
    /// `ended`), stripping any associated value.
    private static func stateLabel(_ state: ChatAgentState) -> String {
        String(describing: state).split(separator: "(").first.map(String.init) ?? "?"
    }
    #endif

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
    /// before app launch are listable. The whole-file JSON read+parse runs off
    /// the main actor; only the (cheap) record application touches main state.
    /// Dead processes register as ended.
    ///
    /// - Parameter agentSources: The agent store files to read.
    func seedFromHookStores(agentSources: [String] = ["claude", "codex"]) async {
        let store = hookStore
        let parsed: [(source: String, entries: [AgentChatHookSessionStore.Entry])] =
            await Task.detached(priority: .utility) {
                agentSources.map { (source: $0, entries: store.entries(agentSource: $0)) }
            }.value
        for (source, entries) in parsed {
            let kind = ChatAgentKind(source: source)
            for entry in entries {
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
        #if DEBUG
        cmuxDebugLog(
            "agentChat.hook session=\(sessionID.prefix(8)) event=\(event.hookEventName.rawValue) "
            + "source=\(event.source) tool=\(event.toolName ?? "-") "
            + "toolInput=\(event.toolInputJSON != nil ? "yes" : "no") "
            + "surface=\((event.surfaceId ?? "nil").prefix(8)) "
            + "transcript=\(event.transcriptPath != nil ? "yes" : "no")"
        )
        #endif
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
        // The hook store is a whole-file JSON read+parse; never do it on the
        // main actor. Consult it at most every 30s per session while bindings
        // are still missing (pid can legitimately stay absent), not on every
        // pre/postToolUse during a tool storm. The read is deferred off-main
        // (see backfillBindingsFromStore) and applied later, filling only
        // still-nil fields — so the live event below always wins a disagreement
        // (the store lags the event by one write).
        let needsHookStore = record.surfaceID == nil || record.transcriptPath == nil || record.pid == nil
        let lastConsult = hookStoreConsultedAt[sessionID]
        let shouldConsultStore = needsHookStore
            && (lastConsult.map { event.receivedAt.timeIntervalSince($0) > 30 } ?? true)
        if shouldConsultStore {
            hookStoreConsultedAt[sessionID] = event.receivedAt
        }
        if let workspaceID = event.workspaceId, !workspaceID.isEmpty {
            record.workspaceID = workspaceID
        }
        if let surfaceID = event.surfaceId, !surfaceID.isEmpty {
            record.surfaceID = surfaceID
        }
        if let cwd = event.cwd, !cwd.isEmpty {
            record.workingDirectory = cwd
        }
        if let transcriptPath = event.transcriptPath, !transcriptPath.isEmpty {
            record.transcriptPath = transcriptPath
        }
        record.lastActivityAt = event.receivedAt

        let previous = records[sessionID]
        record.state = Self.nextState(previous: record.state, event: event)
        stampVersion(&record)
        records[sessionID] = record
        syncProcessExitWatch(for: record)
        updateLiveSessionIndex(previous: previous, current: record)
        onRecordChanged?(record, previous)
        if shouldConsultStore {
            backfillBindingsFromStore(sessionID: sessionID, agentSource: event.source)
        }
        return record
    }

    /// Records, from cmux's own authority, that it is resuming `rawSessionID`
    /// onto `surfaceID`. Resume is ALWAYS cmux-initiated, and some agents (codex)
    /// fire NO SessionStart hook on resume, so the hook-driven path would keep the
    /// stale pre-relaunch record: its pid is already dead, the exit watcher flips
    /// it to `.ended`, and the GUI shows it read-only with no composer (and can't
    /// recover, since you can't submit a prompt from a hidden composer). cmux
    /// holds the `(session, surface)` pair at resume time, so it writes that fact
    /// directly instead of waiting for a hook the agent will never send.
    ///
    /// Clearing the pid is essential: re-stamping the record while it still
    /// carries the DEAD pre-relaunch pid would re-arm the exit watcher on that pid
    /// and immediately re-end the session. With pid cleared, no watcher arms and
    /// the session is shown live/editable; the live pid backfills later from the
    /// agent's own hooks (when it has them), which is the safe direction.
    func noteResumeInitiated(
        sessionID rawSessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        let sessionID = Self.normalizedSessionID(rawSessionID, source: source)
        let now = Date()
        #if DEBUG
        cmuxDebugLog(
            "agentChat.resumeInitiated session=\(sessionID.prefix(8)) source=\(source) "
            + "surface=\((surfaceID ?? "nil").prefix(8)) existed=\(records[sessionID] != nil)"
        )
        #endif
        let normalizedSurface = surfaceID.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedWorkspace = workspaceID.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedCwd = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
        if records[sessionID] != nil {
            update(sessionID: sessionID) { record in
                if let normalizedSurface { record.surfaceID = normalizedSurface }
                if let normalizedWorkspace { record.workspaceID = normalizedWorkspace }
                if let normalizedCwd { record.workingDirectory = normalizedCwd }
                record.pid = nil
                record.state = .idle
                record.lastActivityAt = now
            }
            return
        }
        // The seed has not created this record yet (or it was pruned). Create it
        // live so the GUI shows the resumed session immediately; the transcript
        // path resolves on demand from the session id.
        var record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: ChatAgentKind(source: source),
            workspaceID: normalizedWorkspace,
            surfaceID: normalizedSurface,
            workingDirectory: normalizedCwd,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: now,
            title: nil,
            pid: nil
        )
        stampVersion(&record)
        records[sessionID] = record
        syncProcessExitWatch(for: record)
        updateLiveSessionIndex(previous: nil, current: record)
        onRecordChanged?(record, nil)
    }

    /// Reads one session's hook-store entry OFF the main actor and applies any
    /// still-missing bindings on the main actor. The hot path (`noteHookEvent`)
    /// returns immediately; bindings land a moment later via `update`, which
    /// re-tails and pushes if the transcript path just became known. Filling
    /// only nil fields keeps the live event authoritative over the lagging
    /// store.
    private func backfillBindingsFromStore(sessionID: String, agentSource: String) {
        let store = hookStore
        Task { [weak self] in
            let entry = await Task.detached(priority: .utility) {
                store.entry(agentSource: agentSource, sessionID: sessionID)
            }.value
            guard let self, let entry else { return }
            self.applyStoreBackfill(sessionID: sessionID, entry: entry)
        }
    }

    /// Applies a hook-store entry's non-nil bindings to a record, but only when
    /// it actually changes something — so a backfill that learns nothing new
    /// does not bump the version or emit a no-op descriptor push.
    private func applyStoreBackfill(sessionID: String, entry: AgentChatHookSessionStore.Entry) {
        guard let current = records[sessionID] else { return }
        var candidate = current
        candidate.adoptBindings(from: entry, includingPID: current.pid == nil)
        guard candidate.surfaceID != current.surfaceID
            || candidate.workspaceID != current.workspaceID
            || candidate.transcriptPath != current.transcriptPath
            || candidate.workingDirectory != current.workingDirectory
            || candidate.pid != current.pid else { return }
        update(sessionID: sessionID) { record in
            record.adoptBindings(from: entry, includingPID: record.pid == nil)
        }
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
        case .preCompact, .postCompact:
            // Compaction is lifecycle telemetry. It can occur while a session
            // is idle, so it must not create a synthetic working state.
            return previous
        case .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            if case .needsInput = previous { return previous }
            return .needsInput(since: event.receivedAt)
        case .stop:
            return .idle
        case .subagentStart, .subagentStop:
            // Task subagent lifecycle says nothing about the parent
            // session's activity; keep the current state.
            return previous
        case .sessionEnd:
            return .ended
        }
    }
}
