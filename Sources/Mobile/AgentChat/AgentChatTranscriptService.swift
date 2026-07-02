import CMUXAgentLaunch
import CmuxAgentChat
import CmuxTerminal
import Foundation

/// Mac-side facade for the agent chat surface: tracks sessions from hook
/// events, tails their transcripts, serves history pages, and pushes
/// `chat.message` events to subscribed mobile clients.
@MainActor
final class AgentChatTranscriptService {
    /// The push topic chat clients subscribe to.
    static let eventTopic = "chat.message"

    let registry: AgentChatSessionRegistry
    let resolver: AgentChatTranscriptResolver
    private let coding = ChatWireCoding()
    private var tailers: [String: AgentChatTranscriptTailer] = [:]
    /// Drives the live agent-prose streaming preview.
    private var proseStreamer: AgentChatProseStreamer!
    /// Sessions whose transcript could not be resolved; skipped until an
    /// explicit history request retries, so per-hook-event resolution
    /// failures don't rescan the filesystem during tool storms.
    private var failedResolutions: Set<String> = []
    private var codexTranscriptResolutionTasks: [String: Task<Void, Never>] = [:]
    private var codexTranscriptResolutionKeys: [String: CodexTranscriptResolutionKey] = [:]

    /// Creates the service with a hook-store-backed registry.
    ///
    /// - Parameter resolver: Transcript path resolver.
    convenience init(resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver()) {
        self.init(registry: AgentChatSessionRegistry(), resolver: resolver)
    }

    /// Creates the service with explicit dependencies.
    ///
    /// - Parameters:
    ///   - registry: Session registry.
    ///   - resolver: Transcript path resolver.
    init(
        registry: AgentChatSessionRegistry,
        resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver()
    ) {
        self.registry = registry
        self.resolver = resolver
        registry.onRecordChanged = { [weak self] record, previous in
            self?.handleRecordChange(record, previous: previous)
        }
        self.proseStreamer = AgentChatProseStreamer(
            emit: { [weak self] frame in self?.emit(frame: frame) },
            snapshot: { surfaceID in Self.screenRows(surfaceID: surfaceID) },
            hasSubscribers: { MobileHostService.hasEventSubscribers(topic: Self.eventTopic) }
        )
    }

    /// Rendered screen rows (top to bottom) for a surface, the source the prose
    /// streamer scrapes. Mirrors the render-grid observer's surface lookup.
    @MainActor
    private static func screenRows(surfaceID: UUID) -> [String]? {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else {
            return nil
        }
        return surface.mobileRenderGridFrame(stateSeq: 0, full: true)?.rows
    }

    /// A `(session, surface)` resume re-bind cmux authored during session
    /// restore, buffered until the service is live (restore can run before app
    /// setup assigns this service, so a direct call would be a silent no-op).
    private struct PendingResumeIntent {
        let sessionID: String
        let source: String
        let surfaceID: String?
        let workspaceID: String?
        let workingDirectory: String?
    }

    /// Resume re-binds recorded before ``start()`` wired the live instance.
    private static var pendingResumeIntents: [PendingResumeIntent] = []
    /// The started service, used to apply resume re-binds immediately once live.
    private static weak var liveInstance: AgentChatTranscriptService?

    /// Records, from cmux's own authority, that it is resuming `sessionID` onto
    /// `surfaceID` (see
    /// ``AgentChatSessionRegistry/noteResumeInitiated(sessionID:source:surfaceID:workspaceID:workingDirectory:)``).
    /// Static so the restore path need not hold a service reference: before the
    /// service starts (restore can run first) the intent is buffered and flushed
    /// in ``start()``; after, it applies immediately.
    static func recordResumeIntent(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        if let live = liveInstance {
            live.noteResumeInitiated(
                sessionID: sessionID,
                source: source,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                workingDirectory: workingDirectory
            )
        } else {
            pendingResumeIntents.append(PendingResumeIntent(
                sessionID: sessionID,
                source: source,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                workingDirectory: workingDirectory
            ))
        }
    }

    /// Seeds the session registry from the on-disk hook stores. Call once
    /// at app startup. Sessions are tracked only via the reliable hook-event
    /// path thereafter; cmux does not detect agents that never fire a hook.
    func start() {
        Self.liveInstance = self
        // Apply resume re-binds buffered before the service was wired. The seed
        // only creates records that don't already exist, so an intent applied
        // here is preserved (the seed skips it) and one applied after flips the
        // seeded `.ended` record to `.idle`: either order converges.
        let buffered = Self.pendingResumeIntents
        Self.pendingResumeIntents.removeAll()
        for intent in buffered {
            registry.noteResumeInitiated(
                sessionID: intent.sessionID,
                source: intent.source,
                surfaceID: intent.surfaceID,
                workspaceID: intent.workspaceID,
                workingDirectory: intent.workingDirectory
            )
        }
        // Seeding reads+parses the hook-store JSON off the main actor; kick it
        // off and return. Live hook events also populate the registry, and the
        // seed converges within milliseconds.
        Task { [weak self] in await self?.registry.seedFromHookStores() }
    }

    /// Ingests one hook event (called from the socket dispatch path).
    ///
    /// - Parameter event: The hook event.
    func noteHookEvent(_ event: WorkstreamEvent) {
        let record = registry.noteHookEvent(event)
        // A session (re)starting or receiving a prompt is the bounded
        // retry point for a transcript that didn't exist at first sight.
        switch event.hookEventName {
        case .sessionStart, .userPromptSubmit:
            failedResolutions.remove(record.sessionID)
        default:
            break
        }
        // Tail eagerly only while someone is listening, and never for an
        // ended session (its transcript can no longer grow; recreating the
        // tailer here would undo the ended-state eviction).
        if record.state != .ended,
           MobileHostService.hasEventSubscribers(topic: Self.eventTopic) {
            ensureTailer(for: record)
        }
        // Drive the live prose-streaming preview off the turn lifecycle: a
        // prompt starts the in-flight turn, Stop ends it.
        switch event.hookEventName {
        case .userPromptSubmit:
            if record.state != .ended,
               let surfaceID = record.surfaceID.flatMap(UUID.init(uuidString:)) {
                proseStreamer.turnStarted(
                    sessionID: record.sessionID,
                    surfaceID: surfaceID,
                    agentKind: record.agentKind
                )
            }
        case .stop, .sessionEnd:
            proseStreamer.turnEnded(sessionID: record.sessionID)
        default:
            break
        }
    }

    /// Lists chat-capable sessions.
    ///
    /// - Parameter workspaceID: Workspace UUID string filter, or `nil`.
    /// - Returns: Wire descriptors, most recent first.
    func sessionDescriptors(workspaceID: String?) -> [ChatSessionDescriptor] {
        registry.sessions(workspaceID: workspaceID).map(\.descriptor)
    }

    /// Lists raw session records for callers that must validate live
    /// terminal bindings before exposing descriptors.
    ///
    /// - Parameter workspaceID: Workspace UUID string filter, or `nil`.
    /// - Returns: Matching records, most recent first.
    func sessionRecords(workspaceID: String?) -> [AgentChatSessionRecord] {
        registry.sessions(workspaceID: workspaceID)
    }

    /// Observe-floor detection: discover live codex/claude sessions from the
    /// process table (no hooks required) and fold them into the registry.
    /// Throttled; intended to run on the iOS list pull so a fresh detection
    /// appears the moment the GUI asks for the list.
    func observeAgentProcesses() async {
        await registry.observeAgentProcesses()
    }

    /// The registry record for a session (send path needs the terminal
    /// binding).
    ///
    /// - Parameter sessionID: Raw session id.
    /// - Returns: The record, or `nil` when unknown.
    func sessionRecord(sessionID: String) -> AgentChatSessionRecord? {
        registry.record(sessionID: sessionID)
    }

    /// Re-adopts one session's terminal bindings from the hook store; see
    /// ``AgentChatSessionRegistry/refreshBindingsFromHookStore(sessionID:)``.
    @discardableResult
    func refreshSessionBindings(sessionID: String) async -> AgentChatSessionRecord? {
        await registry.refreshBindingsFromHookStore(sessionID: sessionID)
    }

    /// cmux-authored resume re-bind (see
    /// ``AgentChatSessionRegistry/noteResumeInitiated(sessionID:source:surfaceID:workspaceID:workingDirectory:)``).
    /// Called from the session-restore path when cmux auto-resumes an agent, so
    /// the GUI reflects the live session immediately instead of waiting for a
    /// SessionStart hook the agent (codex) does not fire on resume.
    func noteResumeInitiated(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: source,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory
        )
    }

    /// Re-stamps a session's stored workspace id to the workspace its surface
    /// currently lives in. cmux workspace ids regenerate on every Mac relaunch
    /// while surface ids are stable, so a session created before the last
    /// relaunch carries a stale `workspaceID`. The caller resolves the session's
    /// live surface to its current workspace and calls this so the seed and the
    /// live `descriptorChanged` pushes both scope to that workspace (the iOS
    /// reducer is workspace-scoped and rejects stale-workspace live updates).
    ///
    /// - Parameters:
    ///   - sessionID: The session to re-stamp.
    ///   - workspaceID: The surface's current workspace UUID string.
    func updateSessionWorkspace(sessionID: String, workspaceID: String) {
        registry.update(sessionID: sessionID) { $0.workspaceID = workspaceID }
    }

    /// Serves one history page, starting the session's tailer on demand.
    ///
    /// - Parameters:
    ///   - sessionID: The session to read.
    ///   - beforeSeq: Strict upper bound, or `nil` for the newest page.
    ///   - limit: Page size cap.
    /// - Returns: The page, or `nil` when the session or transcript is
    ///   unknown.
    func history(sessionID: String, beforeSeq: Int?, limit: Int) async -> ChatHistoryPage? {
        guard let record = registry.record(sessionID: sessionID) else { return nil }
        // A user opening the chat is the right moment to retry a previously
        // failed transcript resolution.
        failedResolutions.remove(sessionID)
        if record.agentKind == .codex,
           resolver.recordedTranscriptPath(for: record) == nil {
            let resolved = await codexTranscriptPathOffMain(for: record)
            applyDirectCodexTranscriptResolution(resolved, sessionID: sessionID)
        }
        guard let currentRecord = registry.record(sessionID: sessionID) else { return nil }
        guard let tailer = ensureTailer(for: currentRecord) else { return nil }
        await tailer.start()
        let page = await tailer.history(beforeSeq: beforeSeq, limit: limit)
        if currentRecord.title == nil, let title = await tailer.title {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        return page
    }

    /// Debug-socket dump of every registry record plus tailer liveness.
    func debugSessionDump() -> [[String: Any]] {
        registry.sessions(workspaceID: nil).map { record in
            var entry: [String: Any] = [
                "session_id": record.sessionID,
                "agent": record.agentKind.sourceName,
                "state": String(describing: record.state),
                "last_activity": record.lastActivityAt.timeIntervalSince1970,
                "tailer_active": tailers[record.sessionID] != nil,
                "resolution_failed": failedResolutions.contains(record.sessionID),
            ]
            entry["workspace_id"] = record.workspaceID
            entry["surface_id"] = record.surfaceID
            entry["transcript_path"] = record.transcriptPath
            if let pid = record.pid {
                entry["pid"] = pid
                entry["pid_alive"] = kill(pid_t(pid), 0) == 0
            }
            return entry
        }
    }

    // MARK: - Internals

    private typealias CodexTranscriptResolutionKey = (
        sessionID: String,
        transcriptPath: String?
    )

    @discardableResult
    private func ensureTailer(for record: AgentChatSessionRecord) -> AgentChatTranscriptTailer? {
        if let existing = tailers[record.sessionID] {
            return existing
        }
        guard !failedResolutions.contains(record.sessionID) else { return nil }
        let resolvedPath: String?
        if record.agentKind == .codex {
            guard let recordedPath = resolver.recordedTranscriptPath(for: record) else {
                scheduleCodexTranscriptResolution(for: record)
                return nil
            }
            resolvedPath = recordedPath
        } else {
            resolvedPath = resolver.transcriptPath(for: record)
        }
        guard let path = resolvedPath else {
            failedResolutions.insert(record.sessionID)
            #if DEBUG
            cmuxDebugLog(
                "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
                + "kind=\(record.agentKind.sourceName) cwd=\(record.workingDirectory ?? "nil") UNRESOLVED"
            )
            #endif
            return nil
        }
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
            + "file=\((path as NSString).lastPathComponent)"
        )
        #endif
        if record.transcriptPath != path {
            registry.update(sessionID: record.sessionID) { $0.transcriptPath = path }
        }
        let sessionID = record.sessionID
        let agentKind = record.agentKind
        let tailer = AgentChatTranscriptTailer(
            sessionID: sessionID,
            agentKind: agentKind,
            path: path
        ) { [weak self] batch in
            await self?.publishBatch(batch, sessionID: sessionID)
        }
        tailers[sessionID] = tailer
        Task { await tailer.start() }
        return tailer
    }

    private func publishBatch(_ batch: AgentChatTranscriptTailer.Batch, sessionID: String) {
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.batch session=\(sessionID.prefix(8)) "
            + "appended=\(batch.appended.count) updated=\(batch.updated.count) "
            + "reset=\(batch.didReset ? 1 : 0) title=\(batch.discoveredTitle != nil ? 1 : 0)"
        )
        #endif
        if batch.didReset {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .reset))
        }
        if let title = batch.discoveredTitle {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        if !batch.appended.isEmpty {
            // The authoritative prose for the turn just landed: settle the live
            // preview so the committed message takes over with no duplicate.
            if Self.batchContainsAgentProse(batch.appended) {
                proseStreamer.authoritativeProseArrived(sessionID: sessionID)
            }
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .appended(batch.appended)))
        }
        if !batch.updated.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .updated(batch.updated)))
        }
        if let completedAt = Self.completedAssistantTurnTimestamp(in: batch.appended) {
            registry.noteAssistantTurnCompleted(sessionID: sessionID, at: completedAt)
        }
    }

    /// Whether a batch carries any committed agent prose, the signal that the
    /// streaming preview for the turn should settle.
    private static func batchContainsAgentProse(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            guard message.role == .agent else { return false }
            if case .prose = message.kind { return true }
            return false
        }
    }

    private static func completedAssistantTurnTimestamp(in messages: [ChatMessage]) -> Date? {
        guard !messages.isEmpty else { return nil }
        var completedAt: Date?
        for message in messages where message.role == .agent {
            switch message.kind {
            case .prose, .thought, .unsupported:
                completedAt = max(completedAt ?? message.timestamp, message.timestamp)
            case .toolUse, .terminal, .fileEdit, .permissionRequest, .question:
                return nil
            case .status:
                break
            case .attachment:
                break
            }
        }
        return completedAt
    }

    private func handleRecordChange(_ record: AgentChatSessionRecord, previous: AgentChatSessionRecord?) {
        let stateChanged = previous?.state != record.state
        let transcriptBecameAvailable = previous?.transcriptPath == nil && record.transcriptPath != nil
        if stateChanged, record.state == .ended {
            // The transcript can no longer grow; stop any live preview loop so
            // an agent that exits without a Stop hook doesn't leak the poll task.
            proseStreamer.turnEnded(sessionID: record.sessionID)
            if let tailer = tailers.removeValue(forKey: record.sessionID) {
                // The transcript can no longer grow; release the file watcher
                // and cache instead of holding them until app quit. Evicting
                // only on the TRANSITION keeps unrelated record updates (title
                // discovery while paging an ended session) from churning it.
                Task { await tailer.stop() }
            }
            clearCodexTranscriptResolution(sessionID: record.sessionID)
        }
        guard MobileHostService.hasEventSubscribers(topic: Self.eventTopic) else { return }
        if transcriptBecameAvailable, record.state != .ended {
            ensureTailer(for: record)
        }
        if stateChanged {
            emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .stateChanged(record.state)))
        }
        // Pure activity bumps (every pre/postToolUse moves lastActivityAt)
        // don't merit a descriptor push to every phone; emit only when the
        // descriptor changed beyond the activity timestamp.
        if Self.descriptorChangedMeaningfully(previous: previous, current: record) {
            emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .descriptorChanged(record.descriptor)))
        }
    }

    private static func descriptorChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        return normalizedPrevious.descriptor != current.descriptor
    }

    private func emit(frame: ChatSessionEventFrame) {
        guard let payload = wirePayload(frame) else { return }
        MobileHostService.emitEvent(topic: Self.eventTopic, payload: payload)
    }

    private func scheduleCodexTranscriptResolution(for record: AgentChatSessionRecord) {
        let key: CodexTranscriptResolutionKey = (
            sessionID: record.sessionID,
            transcriptPath: record.transcriptPath
        )
        if let currentKey = codexTranscriptResolutionKeys[record.sessionID],
           currentKey.sessionID == key.sessionID,
           currentKey.transcriptPath == key.transcriptPath {
            return
        }

        clearCodexTranscriptResolution(sessionID: record.sessionID)
        codexTranscriptResolutionKeys[record.sessionID] = key
        let scanTask = detachedCodexTranscriptResolutionTask(for: record)
        codexTranscriptResolutionTasks[record.sessionID] = Task { @MainActor [
            weak self,
            scanTask,
            key
        ] in
            let resolved = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.applyCodexTranscriptResolution(resolved, key: key)
        }
    }

    private func clearCodexTranscriptResolution(sessionID: String) {
        codexTranscriptResolutionTasks[sessionID]?.cancel()
        codexTranscriptResolutionTasks[sessionID] = nil
        codexTranscriptResolutionKeys[sessionID] = nil
    }

    private func codexTranscriptPathOffMain(for record: AgentChatSessionRecord) async -> String? {
        let scanTask = detachedCodexTranscriptResolutionTask(for: record)
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    private func detachedCodexTranscriptResolutionTask(
        for record: AgentChatSessionRecord
    ) -> Task<String?, Never> {
        let resolver = self.resolver
        #if compiler(>=6.2)
        let resolveOperation: @concurrent @Sendable () async -> String? = { [resolver, record] in
            resolver.transcriptPath(for: record)
        }
        #else
        let resolveOperation: @Sendable () async -> String? = { [resolver, record] in
            resolver.transcriptPath(for: record)
        }
        #endif
        return Task.detached(priority: .utility, operation: resolveOperation)
    }

    private func applyCodexTranscriptResolution(
        _ resolved: String?,
        key: CodexTranscriptResolutionKey
    ) {
        guard let currentKey = codexTranscriptResolutionKeys[key.sessionID],
              currentKey.sessionID == key.sessionID,
              currentKey.transcriptPath == key.transcriptPath else {
            return
        }
        codexTranscriptResolutionTasks[key.sessionID] = nil
        codexTranscriptResolutionKeys[key.sessionID] = nil
        // If a hook recorded the authoritative transcript path while this
        // fallback scan was in flight, that recorded path wins. The key match
        // above only proves no *newer scan* was scheduled; it does not see a
        // registry transcript-path update, so guard against overwriting a now-
        // valid recorded path with this (possibly stale) scan result.
        if let record = registry.record(sessionID: key.sessionID),
           resolver.recordedTranscriptPath(for: record) != nil {
            return
        }
        applyDirectCodexTranscriptResolution(resolved, sessionID: key.sessionID)
    }

    /// Applies a resolved Codex transcript path to the registry.
    ///
    /// `internal` (not `private`) so a regression test can drive the
    /// recorded-path guard directly: the race it protects against — a hook
    /// recording the authoritative path while an off-main fallback scan is in
    /// flight — cannot be reproduced deterministically through `history(...)`
    /// alone. Both real callers (`history(...)` and the scheduled resolution)
    /// reach here only after awaiting that scan.
    func applyDirectCodexTranscriptResolution(_ resolved: String?, sessionID: String) {
        guard let record = registry.record(sessionID: sessionID),
              record.agentKind == .codex else {
            return
        }
        guard let resolved else {
            if resolver.recordedTranscriptPath(for: record) == nil {
                failedResolutions.insert(sessionID)
            } else {
                failedResolutions.remove(sessionID)
            }
            return
        }
        failedResolutions.remove(sessionID)
        if record.transcriptPath != resolved {
            registry.update(sessionID: sessionID) { $0.transcriptPath = resolved }
        }
    }

    /// Stops every active tailer and cancels in-flight Codex resolution work so
    /// their file watchers and background tasks do not outlive the service. The
    /// live singleton normally runs for the app's lifetime; callers that own a
    /// transient instance (e.g. tests) call this at teardown so kqueue file
    /// watchers and detached tasks are released deterministically.
    func shutdown() async {
        for task in codexTranscriptResolutionTasks.values { task.cancel() }
        codexTranscriptResolutionTasks.removeAll()
        codexTranscriptResolutionKeys.removeAll()
        for tailer in tailers.values { await tailer.stop() }
        tailers.removeAll()
    }

    /// Encodes a wire value into the `[String: Any]` payload shape the
    /// event fan-out expects.
    func wirePayload<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
