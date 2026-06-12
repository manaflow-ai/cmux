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
        registry.onRecordChanged = { [weak self] record, stateChanged in
            self?.handleRecordChange(record, stateChanged: stateChanged)
        }
    }

    /// Seeds the session registry from the on-disk hook stores. Call once
    /// at app startup.
    func start() {
        registry.seedFromHookStores()
    }

    /// Ingests one hook event (called from the socket dispatch path).
    ///
    /// - Parameter event: The hook event.
    func noteHookEvent(_ event: WorkstreamEvent) {
        let record = registry.noteHookEvent(event)
        // Tail eagerly only while someone is listening; history requests
        // start tailers on demand.
        if MobileHostService.hasEventSubscribers(topic: Self.eventTopic) {
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

    /// The registry record for a session (send path needs the terminal
    /// binding).
    ///
    /// - Parameter sessionID: Raw session id.
    /// - Returns: The record, or `nil` when unknown.
    func sessionRecord(sessionID: String) -> AgentChatSessionRecord? {
        registry.record(sessionID: sessionID)
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
        if let title = batch.discoveredTitle {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        if !batch.appended.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .appended(batch.appended)))
        }
        if !batch.updated.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .updated(batch.updated)))
        }
    }

    private func handleRecordChange(_ record: AgentChatSessionRecord, stateChanged: Bool) {
        if record.state == .ended, let tailer = tailers.removeValue(forKey: record.sessionID) {
            // The transcript can no longer grow; release the file watcher
            // and cache instead of holding them until app quit.
            Task { await tailer.stop() }
        }
        guard MobileHostService.hasEventSubscribers(topic: Self.eventTopic) else { return }
        if stateChanged {
            emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .stateChanged(record.state)))
        }
        emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .descriptorChanged(record.descriptor)))
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
