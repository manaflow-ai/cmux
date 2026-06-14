import CMUXWorkstream
import CmuxAgentChat
import Foundation

/// Mac-side facade for the agent chat surface: tracks sessions from hook
/// events, tails their transcripts, serves history pages, and pushes
/// `chat.message` events to subscribed mobile clients.
@MainActor
final class AgentChatTranscriptService {
    /// Process-wide instance, mirroring the sibling mobile host services
    /// (`MobileHostService.shared`, `MobileTerminalRenderObserver.shared`)
    /// that the socket dispatch reaches statically. lint:allow
    static let shared = AgentChatTranscriptService(
        registry: AgentChatSessionRegistry(),
        resolver: AgentChatTranscriptResolver()
    )

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
    private static let detectionScanThrottle: TimeInterval = 4

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - registry: Session registry; defaults to a hook-store-backed one.
    ///   - resolver: Transcript path resolver.
    init(
        registry: AgentChatSessionRegistry,
        resolver: AgentChatTranscriptResolver
    ) {
        self.registry = registry
        self.resolver = resolver
        registry.onRecordChanged = { [weak self] record, previous in
            self?.handleRecordChange(record, previous: previous)
        }
    }

    /// Seeds the session registry from the on-disk hook stores. Call once
    /// at app startup.
    func start() {
        registry.seedFromHookStores()
        observeAgentTitleChanges()
    }

    /// Watches terminal title changes so a coding agent launched without a
    /// hook (e.g. via a shell wrapper that bypasses cmux's hook injection) is
    /// adopted the instant its terminal title becomes the agent's (e.g.
    /// "✳ Claude Code"), not only when the workspace is next opened. Adoption
    /// emits a descriptor change, which pushes the toggle to listening phones.
    private func observeAgentTitleChanges() {
        NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let title = notification.userInfo?[GhosttyNotificationKey.title] as? String,
                  title.lowercased().contains("claude") else {
                return
            }
            MainActor.assumeIsolated {
                TerminalController.shared.adoptDetectedAgentSessions(workspaceID: tabId.uuidString)
            }
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

    /// Lists chat-capable sessions for known workspace/terminal ids.
    ///
    /// This is the bounded workspace-list path: unrelated historical records
    /// are neither swept nor sorted.
    func sessionDescriptors(
        workspaceAndTerminalIDs: [String: Set<String>]
    ) -> [ChatSessionDescriptor] {
        registry.sessions(workspaceAndSurfaceIDs: workspaceAndTerminalIDs).map(\.descriptor)
    }

    /// Adopts a Claude session cmux detected by terminal title but that
    /// never registered via a hook (e.g. launched through a shell wrapper
    /// that bypasses cmux's hook injection), so it gains a chat session and
    /// toggle like a hooked agent. Resolves the transcript by working
    /// directory; no-op when none exists or the surface already has a live
    /// session.
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
        workingDirectory: String
    ) -> Bool {
        let alreadyBound = registry.sessions(workspaceID: workspaceID)
            .contains { $0.surfaceID == surfaceID && $0.state != .ended }
        if alreadyBound { return true }
        // A claude detected by title before it has written its transcript jsonl
        // (the launch race) resolves to nothing. List-level adoption runs this
        // on every workspace-list RPC and every "claude" title change across
        // ALL workspaces, so without a throttle an un-resolvable surface drives
        // a fresh main-actor directory walk on each call during a title burst.
        // Bound the filesystem scan to once per surface per window; a success
        // clears the entry (and `alreadyBound` short-circuits forever after).
        let now = Date()
        if let lastScan = detectionScanAt[surfaceID],
           now.timeIntervalSince(lastScan) < Self.detectionScanThrottle {
            return false
        }
        detectionScanAt[surfaceID] = now
        guard let resolved = resolver.newestClaudeTranscript(workingDirectory: workingDirectory) else {
            return false
        }
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
        guard let tailer = ensureTailer(for: record) else { return nil }
        await tailer.start()
        let page = await tailer.history(beforeSeq: beforeSeq, limit: limit)
        if record.title == nil, let title = await tailer.title {
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

    @discardableResult
    private func ensureTailer(for record: AgentChatSessionRecord) -> AgentChatTranscriptTailer? {
        if let existing = tailers[record.sessionID] {
            return existing
        }
        guard !failedResolutions.contains(record.sessionID) else { return nil }
        guard let path = resolver.transcriptPath(for: record) else {
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
        if stateChanged, record.state == .ended,
           let tailer = tailers.removeValue(forKey: record.sessionID) {
            // The transcript can no longer grow; release the file watcher
            // and cache instead of holding them until app quit. Evicting
            // only on the TRANSITION keeps unrelated record updates (title
            // discovery while paging an ended session) from churning it.
            Task { await tailer.stop() }
        }
        guard MobileHostService.hasEventSubscribers(topic: Self.eventTopic) else { return }
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
