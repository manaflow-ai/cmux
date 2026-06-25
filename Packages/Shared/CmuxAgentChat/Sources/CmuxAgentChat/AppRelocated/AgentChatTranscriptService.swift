import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// Mac-side facade for the agent chat surface: tracks sessions from hook
/// events, tails their transcripts, serves history pages, and pushes
/// `chat.message` events to subscribed mobile clients.
@MainActor
final class AgentChatTranscriptService {
    /// The push topic chat clients subscribe to.
    static let eventTopic = "chat.message"

    private let registry: AgentChatSessionRegistry
    private let resolver: AgentChatTranscriptResolver
    private let coding = ChatWireCoding()
    private var tailers: [String: AgentChatTranscriptTailer] = [:]
    /// Sessions whose transcript could not be resolved; skipped until an
    /// explicit history request retries, so per-hook-event resolution
    /// failures don't rescan the filesystem during tool storms.
    private var failedResolutions: Set<String> = []
    /// Last time `adoptDetectedClaudeSession` ran a filesystem scan for a
    /// surface that had no session yet, keyed by surface id. Bounds the
    /// main-actor directory walk to once per `detectionScanThrottle` while a
    /// title-detected claude has not yet written its transcript; a successful
    /// adoption removes the entry.
    private var detectionScanAt: [String: Date] = [:]
    private var ghosttyTitleSubscription: GhosttyTitleChangeSubscription?
    private static let detectionScanThrottle: TimeInterval = 4
    private static let provisionalClaudeSessionIDPrefix = "detected-claude-surface-"

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
    }

    /// Seeds the session registry from the on-disk hook stores. Call once
    /// at app startup.
    ///
    /// - Parameter adoptDetectedAgentSessions: Composition-root callback that
    ///   adopts a title-detected agent for the workspace whose title changed.
    func start(adoptDetectedAgentSessions: @escaping @MainActor (String) -> Void) {
        guard ghosttyTitleSubscription == nil else { return }
        registry.seedFromHookStores()
        observeAgentTitleChanges(adoptDetectedAgentSessions: adoptDetectedAgentSessions)
    }

    /// Watches terminal title changes so a coding agent launched without a
    /// hook (e.g. via a shell wrapper that bypasses cmux's hook injection) is
    /// adopted the instant its terminal title becomes the agent's (e.g.
    /// "✳ Claude Code"), not only when the workspace is next opened. Adoption
    /// emits a descriptor change, which pushes the toggle to listening phones.
    private func observeAgentTitleChanges(adoptDetectedAgentSessions: @escaping @MainActor (String) -> Void) {
        ghosttyTitleSubscription = GhosttyTitleChangeSubscription { change in
            guard change.title.lowercased().contains("claude") else {
                return
            }
            adoptDetectedAgentSessions(change.tabId.uuidString)
        }
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

    /// Adopts a Claude session cmux detected by terminal title but that
    /// never registered via a hook (e.g. launched through a shell wrapper
    /// that bypasses cmux's hook injection), so it gains a chat session and
    /// toggle like a hooked agent. Creates a provisional surface-keyed session
    /// before Claude writes its transcript, then attaches the transcript to
    /// that same session once it appears.
    ///
    /// - Parameters:
    ///   - workspaceID: The agent's workspace UUID string.
    ///   - surfaceID: The hosting terminal surface UUID string.
    ///   - workingDirectory: The agent's working directory.
    /// - Returns: `true` when a session is present for the surface afterward.
    @discardableResult
    func adoptDetectedClaudeSession(
        workspaceID: String,
        surfaceID: String,
        workingDirectory: String,
        titleHint: String? = nil
    ) -> Bool {
        if let bound = registry.sessions(workspaceID: nil)
            .first(where: { $0.surfaceID == surfaceID && $0.state != .ended }) {
            registry.update(sessionID: bound.sessionID) { record in
                record.workspaceID = workspaceID
                record.surfaceID = surfaceID
                record.workingDirectory = workingDirectory
            }
            guard bound.transcriptPath == nil else { return true }
            if let resolved = newestClaudeTranscript(
                workingDirectory: workingDirectory,
                surfaceID: surfaceID,
                excludingSessionID: bound.sessionID,
                titleHint: titleHint,
                forceScan: Self.isSpecificClaudeTitle(titleHint)
            ) {
                detectionScanAt.removeValue(forKey: surfaceID)
                registry.update(sessionID: bound.sessionID) { record in
                    record.transcriptPath = resolved.path
                    record.workingDirectory = workingDirectory
                }
            }
            return true
        }
        // A claude detected by title before it has written its transcript jsonl
        // (the launch race) resolves to nothing. List-level adoption runs this
        // on every workspace-list RPC and every "claude" title change across
        // ALL workspaces, so without a throttle an un-resolvable surface drives
        // a fresh main-actor directory walk on each call during a title burst.
        // Bound the filesystem scan to once per surface per window; a success
        // clears the entry (and `alreadyBound` short-circuits forever after).
        if let resolved = newestClaudeTranscript(
            workingDirectory: workingDirectory,
            surfaceID: surfaceID,
            excludingSessionID: nil,
            titleHint: titleHint,
            forceScan: false
        ) {
            detectionScanAt.removeValue(forKey: surfaceID)
            registry.adoptDetectedSession(
                sessionID: resolved.sessionID,
                agentKind: .claude,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                workingDirectory: workingDirectory,
                transcriptPath: resolved.path,
                at: Date()
            )
            return true
        }
        registry.adoptDetectedSession(
            sessionID: Self.provisionalClaudeSessionID(surfaceID: surfaceID),
            agentKind: .claude,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            workingDirectory: workingDirectory,
            transcriptPath: nil,
            at: Date()
        )
        return true
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
    func refreshSessionBindings(sessionID: String) -> AgentChatSessionRecord? {
        registry.refreshBindingsFromHookStore(sessionID: sessionID)
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
        if record.transcriptPath == nil,
           Self.isProvisionalClaudeSessionID(sessionID),
           let workingDirectory = record.workingDirectory,
           let surfaceID = record.surfaceID,
           let resolved = newestClaudeTranscript(
               workingDirectory: workingDirectory,
               surfaceID: surfaceID,
               excludingSessionID: sessionID,
               titleHint: record.title,
               forceScan: true
           ) {
            registry.update(sessionID: sessionID) { $0.transcriptPath = resolved.path }
        }
        guard let currentRecord = registry.record(sessionID: sessionID) else { return nil }
        if currentRecord.transcriptPath == nil,
           Self.isProvisionalClaudeSessionID(sessionID) {
            return ChatHistoryPage(messages: [], hasMore: false)
        }
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
            entry["is_provisional"] = Self.isProvisionalClaudeSessionID(record.sessionID)
            if let pid = record.pid {
                entry["pid"] = pid
                entry["pid_alive"] = kill(pid_t(pid), 0) == 0
            }
            return entry
        }
    }

    // MARK: - Internals

    @discardableResult
    private func ensureTailer(for record: AgentChatSessionRecord) -> AgentChatTranscriptTailer? {
        if let existing = tailers[record.sessionID] {
            return existing
        }
        guard !failedResolutions.contains(record.sessionID) else { return nil }
        guard let path = resolver.transcriptPath(for: record) else {
            if Self.isProvisionalClaudeSessionID(record.sessionID) {
                return nil
            }
            failedResolutions.insert(record.sessionID)
            return nil
        }
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
        if batch.didReset {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .reset))
        }
        if let title = batch.discoveredTitle {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        if !batch.appended.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .appended(batch.appended)))
        }
        if !batch.updated.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .updated(batch.updated)))
        }
        if let completedAt = Self.completedAssistantTurnTimestamp(in: batch.appended) {
            registry.noteAssistantTurnCompleted(sessionID: sessionID, at: completedAt)
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
        if stateChanged, record.state == .ended,
           let tailer = tailers.removeValue(forKey: record.sessionID) {
            // The transcript can no longer grow; release the file watcher
            // and cache instead of holding them until app quit. Evicting
            // only on the TRANSITION keeps unrelated record updates (title
            // discovery while paging an ended session) from churning it.
            Task { await tailer.stop() }
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

    private func newestClaudeTranscript(
        workingDirectory: String,
        surfaceID: String,
        excludingSessionID: String?,
        titleHint: String?,
        forceScan: Bool
    ) -> (sessionID: String, path: String)? {
        let now = Date()
        if !forceScan,
           let lastScan = detectionScanAt[surfaceID],
           now.timeIntervalSince(lastScan) < Self.detectionScanThrottle {
            return nil
        }
        detectionScanAt[surfaceID] = now
        var claimed = registry.claimedSessionIDs()
        if let excludingSessionID {
            claimed.remove(excludingSessionID)
        }
        return resolver.newestClaudeTranscript(
            workingDirectory: workingDirectory,
            excludingSessionIDs: claimed,
            titleHint: titleHint
        )
    }

    private static func provisionalClaudeSessionID(surfaceID: String) -> String {
        provisionalClaudeSessionIDPrefix + surfaceID.lowercased()
    }

    private static func isProvisionalClaudeSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(provisionalClaudeSessionIDPrefix)
    }

    private static func isSpecificClaudeTitle(_ title: String?) -> Bool {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return false
        }
        while let first = title.first, !first.isLetter && !first.isNumber {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = title.lowercased()
        return !normalized.isEmpty
            && normalized != "claude code"
            && !normalized.hasPrefix("claude ·")
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
