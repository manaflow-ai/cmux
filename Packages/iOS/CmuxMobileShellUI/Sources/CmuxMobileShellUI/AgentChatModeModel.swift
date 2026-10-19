import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation
import CmuxAgentChatUI

/// State for the ChatGPT/Codex-style agent mode. The model deliberately owns
/// only presentation state; transport remains behind ``ChatEventSource`` so
/// Claude Code, Codex, and OpenCode share the same event and action pipeline.
@MainActor
@Observable
final class AgentChatModeModel {
    /// Connection state for the source used by agent mode. A source can be
    /// present while its event stream is down, so this is deliberately kept
    /// separate from whether a session list was last loaded successfully.
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    struct PendingAttachment: Identifiable, Sendable, Equatable {
        let id: UUID
        let displayName: String
        let data: Data
        let format: ChatOutboundAttachment.Format
        let thumbnailData: Data?

        init(
            id: UUID = UUID(),
            displayName: String,
            data: Data,
            format: ChatOutboundAttachment.Format,
            thumbnailData: Data? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.data = data
            self.format = format
            self.thumbnailData = thumbnailData
        }

        var outbound: ChatOutboundAttachment {
            ChatOutboundAttachment(data: data, format: format, fileName: format == .file ? displayName : nil)
        }
    }

    /// Presentation state for an attachment that is still being imported
    /// into the composer. The transport only sees ``PendingAttachment`` once
    /// staging succeeds; keeping this state separate lets the composer show
    /// one progress row per selected item and cancel a slow import without
    /// changing the outbound wire format.
    struct AttachmentStagingItem: Identifiable, Sendable, Equatable {
        enum State: Sendable, Equatable {
            case queued
            case loading
            case preparing
            case completed
            case failed
            case cancelled
        }

        let id: UUID
        var displayName: String
        let format: ChatOutboundAttachment.Format
        var state: State
        /// A best-effort fraction. Photos providers do not expose byte-level
        /// progress, so their importer reports phase milestones while files
        /// can report exact read progress.
        var progress: Double

        init(
            id: UUID = UUID(),
            displayName: String,
            format: ChatOutboundAttachment.Format,
            state: State = .queued,
            progress: Double = 0
        ) {
            self.id = id
            self.displayName = displayName
            self.format = format
            self.state = state
            self.progress = min(max(progress, 0), 1)
        }

        var isTerminal: Bool {
            switch state {
            case .completed, .failed, .cancelled:
                return true
            case .queued, .loading, .preparing:
                return false
            }
        }
    }

    private(set) var sessions: [ChatSessionDescriptor] = []
    private(set) var controlsBySession: [String: ChatSessionControls] = [:]
    private(set) var updatingControlsSessionIDs: Set<String> = []
    private(set) var messagesBySession: [String: [ChatMessage]] = [:]
    private(set) var terminalBlocksBySession: [String: [TerminalCommandBlock]] = [:]
    /// Provider-reported token, context, and allowance state, when the host
    /// exposes it. Older hosts leave this absent.
    private(set) var usageBySession: [String: ChatUsageTotals] = [:]
    private(set) var streamingBySession: [String: ChatMessage?] = [:]
    private(set) var loadingSessionIDs: Set<String> = []
    private(set) var sendingSessionIDs: Set<String> = []
    private(set) var interruptingSessionIDs: Set<String> = []
    private(set) var retryingSessionIDs: Set<String> = []
    private(set) var renamingSessionIDs: Set<String> = []
    private(set) var deletingSessionIDs: Set<String> = []
    private(set) var exportingSessionIDs: Set<String> = []
    /// Fork/resume/reopen each create a terminal asynchronously. Keep one
    /// launch in flight per source session so a double tap cannot open two
    /// provider sessions before the first descriptor is published.
    private(set) var launchingSessionIDs: Set<String> = []
    /// Agent responses can be regenerated while an otherwise healthy turn is
    /// idle. Keep this separate from failed-turn retry state so the response
    /// action has its own in-flight guard and presentation state.
    private(set) var regeneratingSessionIDs: Set<String> = []
    /// Review mutations are keyed by session and transcript message so one
    /// slow host operation cannot disable every diff card in the transcript.
    private(set) var reviewingMessageKeys: Set<String> = []
    private(set) var pinnedSessionIDs: Set<String>
    private(set) var archivedSessionIDs: Set<String>
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var errorMessage: String?
    private(set) var attachments: [PendingAttachment] = []
    private(set) var attachmentStaging: [AttachmentStagingItem] = []
    var selectedSessionID: String?
    var draft = ""
    var selectedProvider: String = "all"
    /// Case-insensitive search over the session title, provider, id, and
    /// working directory. Keeping this on the model makes the session list
    /// useful to non-SwiftUI consumers as well.
    var sessionSearchQuery = ""

    private var source: (any AgentChatSessionSource)?
    private var sourceTask: Task<Void, Never>?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var historyReloadTasks: [String: Task<Void, Never>] = [:]
    private var transcriptSearchTask: Task<Void, Never>?
    private var transcriptSearchGeneration = 0
    private var historyCursors: [String: Int] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var transcriptRevisions: [String: Int] = [:]
    private var usageRevisions: [String: Int] = [:]
    private var historyResetTokens: [String: Int] = [:]
    /// Highest host session revision observed for each id. Transcript and
    /// lifecycle pushes can share a revision, so this is intentionally
    /// separate from transcript sequence cursors.
    private var latestVersionBySession: [String: Int] = [:]
    /// Monotonic token for controls reads. A read starts when a session is
    /// selected, but a user change can be acknowledged before that read
    /// returns; the token prevents the older snapshot from overwriting the
    /// acknowledged controls (or a newer descriptor) afterward.
    private var controlsRequestTokens: [String: Int] = [:]
    private var pendingSendsBySession: [String: [QueuedSend]] = [:]
    /// The prompt currently crossing the RPC boundary. Keep it visible until
    /// the authoritative transcript appends the corresponding user message so
    /// a slow host cannot make a successful send look lost.
    private var inFlightSendsBySession: [String: QueuedSend] = [:]
    /// Last prompt that began a turn. The host does not need a provider-
    /// specific retry RPC: retrying resends this exact prompt through the
    /// ordinary send path, preserving the existing terminal binding.
    private var lastTurnBySession: [String: QueuedSend] = [:]
    /// Answer cards can remain visually pending until the host republishes the
    /// resolved transcript message. Keep a local guard so a double tap cannot
    /// submit the same decision twice during that window.
    private var answeringRequestKeys: Set<String> = []
    private var answeredRequestKeysBySession: [String: Set<String>] = [:]
    /// Response sequence captured when regenerate is accepted. The action
    /// remains disabled after the input RPC returns until a newer response (or
    /// a working/failed/needs-input state) proves that the host accepted the
    /// replacement turn.
    private var regenerationBaselineSeqBySession: [String: Int] = [:]
    /// Launch acknowledgements can arrive before provider hook discovery. Keep
    /// the target around so a later descriptor push selects the new terminal.
    private var pendingLaunchSelections: [String: ChatSessionLaunchResult] = [:]
    private var removedSessionVersions: [String: Int] = [:]
    private var sourceGeneration = 0
    private var attachmentStagingGeneration = 0
    private let reconnectDelay: @Sendable (_ attempt: Int) async -> Void
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let pinnedSessionIDsKey = "cmux.mobile.agentChat.pinnedSessionIDs"
    private static let archivedSessionIDsKey = "cmux.mobile.agentChat.archivedSessionIDs"

    init(
        defaults: UserDefaults = .standard,
        reconnectDelay: @escaping @Sendable (_ attempt: Int) async -> Void = AgentChatModeModel.defaultReconnectDelay,
        source: (any AgentChatSessionSource)? = nil
    ) {
        self.defaults = defaults
        self.pinnedSessionIDs = Set(defaults.stringArray(forKey: Self.pinnedSessionIDsKey) ?? [])
        self.archivedSessionIDs = Set(defaults.stringArray(forKey: Self.archivedSessionIDsKey) ?? [])
        self.reconnectDelay = reconnectDelay
        self.source = source
        self.connectionState = source == nil ? .disconnected : .connecting
    }

    /// Keep a dead transport from turning an EOF into a busy resubscribe loop.
    /// The delay is cancellable, so replacing the source or leaving the mode
    /// stops recovery immediately. Tests can inject an immediate delay.
    private nonisolated static func defaultReconnectDelay(attempt: Int) async {
        let milliseconds = min(5_000, 250 * (1 << min(max(attempt - 1, 0), 4)))
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private struct QueuedSend: Sendable {
        let text: String
        let attachments: [PendingAttachment]
    }

    var visibleSessions: [ChatSessionDescriptor] {
        filteredSessions(includeArchived: false)
    }

    var visibleArchivedSessions: [ChatSessionDescriptor] {
        filteredSessions(includeArchived: true).filter { archivedSessionIDs.contains($0.id) }
    }

    /// Keeps the detail column inside the active provider/search scope. A
    /// filter can change without going through `select`, so reconcile the
    /// current conversation instead of leaving a stale transcript visible.
    func reconcileSelectionToFilter() {
        guard let selectedSessionID else {
            if let first = visibleSessions.first { select(first) }
            return
        }
        if !visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            if let first = visibleSessions.first {
                select(first)
            } else {
                self.selectedSessionID = nil
            }
        }
    }

    var pinnedSessions: [ChatSessionDescriptor] {
        visibleSessions.filter { pinnedSessionIDs.contains($0.id) }
    }

    func togglePinned(_ sessionID: String) {
        if pinnedSessionIDs.contains(sessionID) {
            pinnedSessionIDs.remove(sessionID)
        } else {
            pinnedSessionIDs.insert(sessionID)
        }
        persistSessionCollections()
    }

    func toggleArchived(_ sessionID: String) {
        if archivedSessionIDs.contains(sessionID) {
            archivedSessionIDs.remove(sessionID)
        } else {
            archivedSessionIDs.insert(sessionID)
            pinnedSessionIDs.remove(sessionID)
            if selectedSessionID == sessionID {
                let next = visibleSessions.first { $0.id != sessionID }
                selectedSessionID = next?.id
                if let next { select(next) }
            }
        }
        persistSessionCollections()
    }

    /// Renames the selected conversation through the host's authoritative
    /// session source. The descriptor push is the source of truth; refreshing
    /// on success also covers older hosts that do not publish descriptor
    /// changes for metadata-only actions.
    func renameSelectedSession(title: String) async {
        guard let sessionID = selectedSessionID,
              let source,
              renamingSessionIDs.insert(sessionID).inserted else { return }
        defer { renamingSessionIDs.remove(sessionID) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a name for this session."
            return
        }
        let generation = sourceGeneration
        do {
            try await source.rename(sessionID: sessionID, title: trimmed)
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            if let descriptor = try? await source.session(sessionID: sessionID) {
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                upsert(descriptor)
            }
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the selected conversation from the host's history surface.
    /// The source may publish a `sessionRemoved` frame; local removal keeps
    /// the UI deterministic when that push is unavailable.
    func deleteSelectedSession() async {
        guard let sessionID = selectedSessionID,
              let source,
              deletingSessionIDs.insert(sessionID).inserted else { return }
        defer { deletingSessionIDs.remove(sessionID) }
        let generation = sourceGeneration
        do {
            try await source.delete(sessionID: sessionID)
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            removeSessionLocally(sessionID)
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Loads a Markdown export for the selected conversation. The view owns
    /// presentation through `ShareLink`, while this model keeps transport and
    /// duplicate-request guards testable.
    func exportSelectedTranscript() async -> String? {
        guard let sessionID = selectedSessionID,
              let source,
              exportingSessionIDs.insert(sessionID).inserted else { return nil }
        defer { exportingSessionIDs.remove(sessionID) }
        let generation = sourceGeneration
        do {
            let transcript = try await source.exportTranscript(sessionID: sessionID)
            guard !Task.isCancelled, generation == sourceGeneration else { return nil }
            return transcript
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var isLaunchingSelectedSession: Bool {
        guard let selectedSessionID else { return false }
        return launchingSessionIDs.contains(selectedSessionID)
    }

    /// Starts a provider-native side chat in a new sibling terminal.
    func forkSelectedSession() async {
        await launchSelectedSession(action: .fork)
    }

    /// Opens the durable provider session in a new terminal. This is useful
    /// for ended history as well as live sessions whose terminal moved.
    func resumeSelectedSession() async {
        await launchSelectedSession(action: .resume)
    }

    /// Explicit wording for the same durable-session launch used by a detail
    /// menu's “Reopen in terminal” action.
    func reopenSelectedSession() async {
        await launchSelectedSession(action: .reopen)
    }

    private func launchSelectedSession(action: ChatSessionLaunchResult.Action) async {
        guard let sessionID = selectedSessionID,
              let source,
              launchingSessionIDs.insert(sessionID).inserted else { return }
        defer { launchingSessionIDs.remove(sessionID) }
        let generation = sourceGeneration
        do {
            let result: ChatSessionLaunchResult
            switch action {
            case .fork:
                result = try await source.fork(sessionID: sessionID)
            case .resume:
                result = try await source.resume(sessionID: sessionID)
            case .reopen:
                result = try await source.reopen(sessionID: sessionID)
            }
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            pendingLaunchSelections[sessionID] = result
            await refresh()
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            selectPendingLaunchIfAvailable()
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func removeSessionLocally(_ sessionID: String) {
        apply(.sessionRemoved(version: Int.max), to: sessionID)
    }

    /// Builds an artifact loader bound to the currently connected Mac and
    /// session. The loader remains optional so offline fixtures and older
    /// hosts still render the transcript without a preview affordance.
    func artifactLoader(for sessionID: String) -> ChatArtifactLoader? {
        guard let source else { return nil }
        return ChatArtifactLoader(
            source: source,
            sessionID: sessionID,
            sourceIdentity: "agent-chat-\(sourceGeneration)-\(sessionID)"
        )
    }

    private func filteredSessions(includeArchived: Bool) -> [ChatSessionDescriptor] {
        let query = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return sessions.filter { session in
            if !includeArchived && archivedSessionIDs.contains(session.id) { return false }
            guard selectedProvider == "all" || session.agentKind.sourceName == selectedProvider else {
                return false
            }
            guard !query.isEmpty else { return true }
            let fields = [
                session.title,
                session.id,
                session.agentKind.displayName,
                session.workingDirectory,
                session.workspaceID,
                session.terminalID,
            ].compactMap { $0 }
            if fields.contains(where: { field in
                field.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }) { return true }
            // History is loaded lazily, so this covers the transcript already
            // hydrated for a session without turning the sidebar search into
            // an unbounded network fan-out.
            return (messagesBySession[session.id] ?? []).contains {
                searchableText(for: $0).folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(query)
            }
        }
    }

    private func searchableText(for message: ChatMessage) -> String {
        switch message.kind {
        case .prose(let value): return value.text
        case .thought(let value): return value.text
        case .toolUse(let value):
            return [value.summary, value.inputDetail, value.output, value.referencedPaths?.joined(separator: " ")]
                .compactMap { $0 }.joined(separator: " ")
        case .webSearch(let value):
            return ([value.query] + value.sources.flatMap { [$0.title, $0.url, $0.snippet] })
                .compactMap { $0 }.joined(separator: " ")
        case .terminal(let value):
            return [value.command, value.output].compactMap { $0 }.joined(separator: " ")
        case .fileEdit(let value): return [value.filePath, value.unifiedDiff].compactMap { $0 }.joined(separator: " ")
        case .permissionRequest(let value): return [value.title, value.subject].joined(separator: " ")
        case .question(let value): return ([value.prompt] + value.options.map(\.label)).joined(separator: " ")
        case .status(let value): return value.detail ?? value.event.rawValue
        case .attachment(let value): return [value.displayName, value.hostPath].compactMap { $0 }.joined(separator: " ")
        case .unsupported(let value): return value.rawType
        }
    }

    private func persistSessionCollections() {
        defaults.set(pinnedSessionIDs.sorted(), forKey: Self.pinnedSessionIDsKey)
        defaults.set(archivedSessionIDs.sorted(), forKey: Self.archivedSessionIDsKey)
    }

    var selectedSession: ChatSessionDescriptor? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedControls: ChatSessionControls {
        guard let session = selectedSession else { return ChatSessionControls() }
        return controlsBySession[session.id] ?? session.controls
    }

    var selectedMessages: [ChatMessage] {
        guard let selectedSessionID else { return [] }
        return messagesBySession[selectedSessionID] ?? []
    }

    /// Number of approval and question cards that still need a response in
    /// the selected transcript. The host's lifecycle state is authoritative
    /// for whether the agent is blocked; this count is only the detail needed
    /// to explain what the user should act on without guessing from the
    /// provider-specific state machine.
    var selectedPendingActionableCount: Int {
        selectedMessages.reduce(into: 0) { count, message in
            switch message.kind {
            case .permissionRequest(let request) where request.resolution == nil:
                count += 1
            case .question(let question) where question.selectedOptionLabel == nil:
                count += 1
            default:
                break
            }
        }
    }

    var selectedStreamingMessage: ChatMessage? {
        guard let selectedSessionID else { return nil }
        return streamingBySession[selectedSessionID] ?? nil
    }

    /// The latest assistant prose in the selected transcript. A regenerate
    /// action belongs to this response only; older responses remain immutable
    /// and can still be copied or edited through their normal message menu.
    var latestAgentResponseID: String? {
        guard let selectedSessionID else { return nil }
        return latestAgentResponse(in: selectedSessionID)?.id
    }

    /// Whether the latest agent response can be replayed through the ordinary
    /// send transport. The host's session state remains authoritative: an
    /// active turn, pending approval/question, queued prompt, or ended session
    /// must not accept a second turn from a stale context menu.
    var canRegenerateLatestResponse: Bool {
        guard let selectedSessionID,
              let selectedSession,
              selectedSession.state != .ended,
              !selectedSession.isWorking,
              selectedPendingActionableCount == 0,
              pendingSendsBySession[selectedSessionID, default: []].isEmpty,
              inFlightSendsBySession[selectedSessionID] == nil,
              !regeneratingSessionIDs.contains(selectedSessionID),
              latestAgentResponse(in: selectedSessionID) != nil,
              let queued = lastTurnBySession[selectedSessionID] else { return false }
        let latestPrompt = latestUserPrompt(in: selectedSessionID)
        return latestPrompt == normalizedPrompt(queued.text)
    }

    var selectedTerminalBlocks: [TerminalCommandBlock] {
        guard let selectedSessionID else { return [] }
        return terminalBlocksBySession[selectedSessionID] ?? []
    }

    var selectedUsage: ChatUsageTotals? {
        guard let selectedSessionID else { return nil }
        return usageBySession[selectedSessionID]
    }

    var selectedHasMoreHistory: Bool {
        guard let selectedSessionID else { return false }
        return historyHasMore[selectedSessionID] == true
    }

    var queuedSendCount: Int {
        guard let selectedSessionID else { return 0 }
        return pendingSendsBySession[selectedSessionID]?.count ?? 0
    }

    /// Prompts accepted locally but not yet present in the authoritative
    /// transcript. The first item is crossing the transport; later items wait
    /// behind it in the client queue.
    var selectedPendingPrompts: [String] {
        guard let selectedSessionID else { return [] }
        var prompts: [String] = []
        if let inFlight = inFlightSendsBySession[selectedSessionID] {
            prompts.append(inFlight.text)
        }
        prompts.append(contentsOf: pendingSendsBySession[selectedSessionID, default: []].map(\.text))
        return prompts
    }

    /// Whether an answer RPC for a visible actionable card is still in flight.
    /// The host republishes the resolved card asynchronously, so the view needs
    /// a local pending state to disable duplicate taps and show progress.
    func isAnswering(requestID: String) -> Bool {
        guard let selectedSessionID else { return false }
        return answeringRequestKeys.contains("\(selectedSessionID):\(requestID)")
    }

    var canRetrySelectedTurn: Bool {
        guard let selectedSession,
              case .failed = selectedSession.state,
              lastTurnBySession[selectedSession.id] != nil else { return false }
        return !retryingSessionIDs.contains(selectedSession.id)
    }

    var selectedFailureReason: String? {
        guard let selectedSession,
              case .failed(_, let reason) = selectedSession.state else { return nil }
        return reason
    }

    func updateSource(_ next: (any AgentChatSessionSource)?) {
        sourceGeneration += 1
        let generation = sourceGeneration
        sourceTask?.cancel()
        transcriptSearchTask?.cancel()
        transcriptSearchTask = nil
        transcriptSearchGeneration &+= 1
        for task in sessionTasks.values { task.cancel() }
        for task in historyReloadTasks.values { task.cancel() }
        sessionTasks = [:]
        historyReloadTasks = [:]
        source = next
        connectionState = next == nil ? .disconnected : .connecting
        sessions = []
        controlsBySession = [:]
        messagesBySession = [:]
        terminalBlocksBySession = [:]
        usageBySession = [:]
        streamingBySession = [:]
        selectedSessionID = nil
        attachments = []
        attachmentStaging = []
        attachmentStagingGeneration &+= 1
        historyCursors = [:]
        historyHasMore = [:]
        transcriptRevisions = [:]
        historyResetTokens = [:]
        latestVersionBySession = [:]
        controlsRequestTokens = [:]
        usageRevisions = [:]
        pendingSendsBySession = [:]
        inFlightSendsBySession = [:]
        lastTurnBySession = [:]
        answeringRequestKeys = []
        answeredRequestKeysBySession = [:]
        regenerationBaselineSeqBySession = [:]
        removedSessionVersions = [:]
        loadingSessionIDs = []
        sendingSessionIDs = []
        interruptingSessionIDs = []
        retryingSessionIDs = []
        regeneratingSessionIDs = []
        launchingSessionIDs = []
        pendingLaunchSelections = [:]
        updatingControlsSessionIDs = []
        reviewingMessageKeys = []
        guard let next else { return }
        sourceTask = Task { [weak self] in
            await self?.loadAndObserve(source: next, generation: generation)
        }
    }

    /// Starts a cancellable background search over transcript history that has
    /// not been opened in the current UI session yet. Metadata matching stays
    /// synchronous through ``visibleSessions``; this fills in message content
    /// without making each keystroke block the sidebar or issuing work after a
    /// new source has replaced the old one.
    func beginTranscriptSearch() {
        transcriptSearchGeneration &+= 1
        let searchGeneration = transcriptSearchGeneration
        transcriptSearchTask?.cancel()
        transcriptSearchTask = nil
        transcriptSearchTask = Task { [weak self] in
            await self?.hydrateTranscriptSearch(generation: searchGeneration)
        }
    }

    /// Deterministic form used by non-UI callers and tests that need to wait
    /// until transcript content is available for a query.
    func searchTranscripts() async {
        transcriptSearchTask?.cancel()
        transcriptSearchGeneration &+= 1
        await hydrateTranscriptSearch(generation: transcriptSearchGeneration)
    }

    private func hydrateTranscriptSearch(generation searchGeneration: Int) async {
        let query = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let source else { return }
        let sourceGeneration = self.sourceGeneration
        let sessionIDs = sessions.map(\.id)
        for sessionID in sessionIDs {
            guard !Task.isCancelled,
                  transcriptSearchGeneration == searchGeneration,
                  sourceGeneration == self.sourceGeneration else { return }
            await loadHistory(
                sessionID: sessionID,
                source: source,
                reset: messagesBySession[sessionID] == nil,
                generation: sourceGeneration
            )
            // A search needs the complete transcript, not just the newest
            // page. The cursor/hasMore guard also prevents a malformed
            // host page from causing an infinite request loop.
            while historyHasMore[sessionID] == true {
                guard !Task.isCancelled,
                      transcriptSearchGeneration == searchGeneration,
                      sourceGeneration == self.sourceGeneration else { return }
                let cursor = historyCursors[sessionID]
                await loadHistory(
                    sessionID: sessionID,
                    source: source,
                    reset: false,
                    generation: sourceGeneration
                )
                guard historyCursors[sessionID] != cursor else { break }
            }
        }
    }

    func refresh() async {
        guard let source else { return }
        let generation = sourceGeneration
        // Host streams finish when the transport closes. Re-open the stream
        // as part of an explicit refresh so a recovered connection resumes
        // receiving live session updates.
        if connectionState == .reconnecting {
            sourceTask?.cancel()
            connectionState = .connecting
            sourceTask = Task { [weak self] in
                await self?.observeHostEvents(source: source, generation: generation)
            }
        }
        await loadSessions(source: source, generation: generation)
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        if let selectedSessionID {
            await loadHistory(
                sessionID: selectedSessionID,
                source: source,
                reset: true,
                generation: generation
            )
        }
    }

    func select(_ session: ChatSessionDescriptor) {
        selectedSessionID = session.id
        draft = ""
        attachments = []
        attachmentStaging = []
        attachmentStagingGeneration &+= 1
        let staleSessionIDs = sessionTasks.keys.filter { $0 != session.id }
        for id in staleSessionIDs {
            sessionTasks[id]?.cancel()
            sessionTasks[id] = nil
        }
        guard let source else { return }
        let generation = sourceGeneration
        sessionTasks[session.id]?.cancel()
        controlsRequestTokens[session.id, default: 0] &+= 1
        let controlsRequestToken = controlsRequestTokens[session.id]!
        // The host-wide stream already carries transcript events for this
        // session with their revisions intact. A second per-session stream
        // would discard those revisions and could replay an old update after
        // the host-wide stream applied a newer one.
        sessionTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            await self.loadHistory(
                sessionID: session.id,
                source: source,
                reset: true,
                generation: generation
            )
        }
        Task { [weak self] in
            guard let self else { return }
            if let controls = try? await source.controls(sessionID: session.id),
               !Task.isCancelled,
               generation == self.sourceGeneration,
               self.controlsRequestTokens[session.id] == controlsRequestToken,
               self.selectedSessionID == session.id {
                self.controlsBySession[session.id] = controls
                if var descriptor = self.sessions.first(where: { $0.id == session.id }) {
                    descriptor.controls = controls
                    self.upsert(descriptor)
                }
            }
        }
    }

    /// Applies controls atomically and leaves the host's acknowledged values
    /// visible while the next descriptor push catches up.
    func updateSelectedControls(_ controls: ChatSessionControls) async {
        guard let sessionID = selectedSessionID, let source,
              selectedSession?.state != .ended,
              updatingControlsSessionIDs.insert(sessionID).inserted else { return }
        defer { updatingControlsSessionIDs.remove(sessionID) }
        // Invalidate a controls read that may have started during selection.
        // The host acknowledgement below is newer than that snapshot.
        controlsRequestTokens[sessionID, default: 0] &+= 1
        let generation = sourceGeneration
        do {
            let acknowledged = try await source.updateControls(controls, sessionID: sessionID)
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            controlsBySession[sessionID] = acknowledged
            if var descriptor = sessions.first(where: { $0.id == sessionID }) {
                descriptor.controls = acknowledged
                upsert(descriptor)
            }
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadOlderMessages() async {
        guard let selectedSessionID, historyHasMore[selectedSessionID] == true,
              let source else { return }
        await loadHistory(
            sessionID: selectedSessionID,
            source: source,
            reset: false,
            generation: sourceGeneration
        )
    }

    func sendDraft() async {
        guard let selectedSessionID,
              let source,
              selectedSession?.state != .ended,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        if pendingAttachments.isEmpty,
           case .needsInput = selectedSession?.state,
           let pendingQuestion = selectedMessages.last(where: { message in
               guard message.role == .agent,
                     case .question(let question) = message.kind else { return false }
               return question.selectedOptionLabel == nil
           }) {
            draft = ""
            await answer(text: text, requestID: pendingQuestion.id)
            return
        }
        draft = ""
        attachments = []
        pendingSendsBySession[selectedSessionID, default: []].append(
            QueuedSend(text: text, attachments: pendingAttachments)
        )
        await drainSendQueue(
            sessionID: selectedSessionID,
            source: source,
            generation: sourceGeneration
        )
    }

    /// Sends a follow-up into the current turn after a polite interrupt. The
    /// regular send action remains a safe queue operation while the agent is
    /// working; this explicit path gives mobile users the provider-style
    /// Steer choice without silently changing queue semantics.
    func steerDraft() async {
        guard let selectedSessionID,
              let source,
              selectedSession?.state != .ended,
              selectedSession?.isWorking == true,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        draft = ""
        attachments = []
        // Steer starts a new effective turn after interrupting the current
        // one. Keep the exact instruction as the retry source just like the
        // ordinary send queue does; otherwise a failure after steering would
        // replay the prompt from the superseded turn.
        lastTurnBySession[selectedSessionID] = QueuedSend(
            text: text,
            attachments: pendingAttachments
        )
        inFlightSendsBySession[selectedSessionID] = lastTurnBySession[selectedSessionID]
        let generation = sourceGeneration
        guard generation == sourceGeneration, !Task.isCancelled else { return }
        do {
            try await source.steer(
                text: text,
                attachments: pendingAttachments.map(\.outbound),
                sessionID: selectedSessionID
            )
            guard generation == sourceGeneration, !Task.isCancelled else { return }
        } catch {
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            inFlightSendsBySession[selectedSessionID] = nil
            draft = text
            attachments = pendingAttachments
            errorMessage = error.localizedDescription
        }
    }

    func addAttachment(_ attachment: PendingAttachment) {
        guard attachments.count < 10 else {
            errorMessage = "You can attach up to 10 attachments."
            return
        }
        let maximumBytes = attachment.format == .file
            ? 32 * 1024 * 1024
            : MobileImageAttachmentPreparer.maximumEncodedBytes
        guard attachment.data.count <= maximumBytes else {
            errorMessage = attachment.format == .file
                ? "That file is too large to send."
                : "That image is too large to send."
            return
        }
        let totalBytes = attachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes + attachment.data.count <= 64 * 1024 * 1024 else {
            errorMessage = "Attachments can use up to 64 MB in total."
            return
        }
        guard !attachments.contains(where: { $0.data == attachment.data }) else { return }
        attachments.append(attachment)
    }

    /// Starts a batch of imports. Callers keep the returned item IDs and use
    /// the update methods below as each provider/file advances. This is
    /// intentionally model-owned so SwiftUI redraws remain deterministic
    /// when a user cancels a picker task or changes sessions mid-import.
    @discardableResult
    func beginAttachmentStaging(_ items: [AttachmentStagingItem]) -> Int {
        attachmentStagingGeneration &+= 1
        attachmentStaging = items
        return attachmentStagingGeneration
    }

    func updateAttachmentStaging(
        id: UUID,
        displayName: String? = nil,
        state: AttachmentStagingItem.State? = nil,
        progress: Double? = nil
    ) {
        guard let index = attachmentStaging.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let displayName {
            attachmentStaging[index].displayName = displayName
        }
        if let state {
            attachmentStaging[index].state = state
        }
        if let progress {
            attachmentStaging[index].progress = min(max(progress, 0), 1)
        }
    }

    func finishAttachmentStagingItem(id: UUID) {
        updateAttachmentStaging(
            id: id,
            state: .completed,
            progress: 1
        )
    }

    func failAttachmentStagingItem(id: UUID) {
        updateAttachmentStaging(id: id, state: .failed)
    }

    /// Marks active rows as cancelled immediately. The importing task still
    /// owns cleanup of provider temporary files; it calls
    /// ``endAttachmentStaging()`` after cancellation has propagated.
    func cancelAttachmentStaging() {
        for index in attachmentStaging.indices where !attachmentStaging[index].isTerminal {
            attachmentStaging[index].state = .cancelled
        }
    }

    func endAttachmentStaging(generation: Int? = nil) {
        if let generation, generation != attachmentStagingGeneration {
            return
        }
        attachmentStaging.removeAll()
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Loads a previously sent user prompt back into the composer so it can be
    /// edited and submitted as a new turn. The host transcript remains
    /// immutable; this mirrors the ChatGPT/Codex mobile affordance where
    /// editing a message creates a fresh draft rather than rewriting history.
    func editPrompt(_ message: ChatMessage) {
        guard selectedSession?.state != .ended,
              message.role == .user,
              case .prose(let prose) = message.kind else { return }
        draft = prose.text
        attachments = []
    }

    /// Stages image content from the system pasteboard. File and text
    /// representations remain available to their native paste paths.
    func stagePastedImages() async {
        let reader = MobilePasteboardReader()
        guard reader.hasAttachmentContent(in: .general) else {
            errorMessage = "No image is available to paste."
            return
        }
        let items = await reader.materializeAttachments(from: .general)
        defer { reader.cleanUp(items) }
        let imageItems = items.filter { $0.kind == .image }
        let remaining = max(0, 10 - attachments.count)
        let selected = Array(imageItems.prefix(remaining))
        let stages = selected.enumerated().map { index, item in
            AttachmentStagingItem(
                displayName: item.displayName.isEmpty ? "Pasted image \(index + 1)" : item.displayName,
                format: .png
            )
        }
        let stagingGeneration = beginAttachmentStaging(stages)
        defer { endAttachmentStaging(generation: stagingGeneration) }
        for (index, item) in selected.enumerated() {
            let stageID = stages[index].id
            guard !Task.isCancelled else { return }
            guard attachments.count < 10 else {
                errorMessage = "You can attach up to 10 images."
                failAttachmentStagingItem(id: stageID)
                return
            }
            updateAttachmentStaging(id: stageID, state: .preparing, progress: 0.3)
            guard let prepared = await prepareImage(at: item.url) else {
                errorMessage = "That image couldn’t be prepared. Choose another image."
                failAttachmentStagingItem(id: stageID)
                continue
            }
            guard !Task.isCancelled else { return }
            updateAttachmentStaging(id: stageID, progress: 0.85)
            let format: ChatOutboundAttachment.Format =
                prepared.format.lowercased() == "jpg" || prepared.format.lowercased() == "jpeg"
                ? .jpeg : .png
            let stem = (item.displayName as NSString).deletingPathExtension
            addAttachment(PendingAttachment(
                displayName: (stem.isEmpty ? "pasted-image" : stem) + (format == .jpeg ? ".jpeg" : ".png"),
                data: prepared.data,
                format: format,
                thumbnailData: prepared.thumbnailData
            ))
            finishAttachmentStagingItem(id: stageID)
        }
    }

    private func prepareImage(at url: URL) async -> MobilePreparedImageAttachment? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            return nil
        }
        guard let size = values.fileSize,
              size <= MobileImageAttachmentPreparer.maximumRawInputBytes else {
            return nil
        }
        return await MobileImageAttachmentPreparer().prepare(url: url)
    }

    func interrupt(hard: Bool = false) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        guard interruptingSessionIDs.insert(selectedSessionID).inserted else { return }
        defer { interruptingSessionIDs.remove(selectedSessionID) }
        let generation = sourceGeneration
        guard generation == sourceGeneration, !Task.isCancelled else { return }
        do {
            try await source.interrupt(sessionID: selectedSessionID, hard: hard)
        } catch {
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Replays the most recent prompt after a provider-reported turn failure.
    /// The session remains in its failed state until the host publishes the
    /// authoritative working/idle transition, so a successful RPC cannot make
    /// the UI claim a retry started when terminal delivery was only queued.
    func retryLastTurn() async {
        guard let selectedSessionID,
              let source,
              let selectedSession,
              case .failed = selectedSession.state,
              let queued = lastTurnBySession[selectedSessionID],
              retryingSessionIDs.insert(selectedSessionID).inserted else { return }
        defer { retryingSessionIDs.remove(selectedSessionID) }
        // A failed queued send is reinserted at the head of the queue. Retry
        // transmits that item directly, so consume the matching queue entry
        // first; otherwise the next ordinary send would deliver the same
        // prompt a second time after a successful retry.
        if var pending = pendingSendsBySession[selectedSessionID],
           let first = pending.first,
           first.text == queued.text,
           first.attachments == queued.attachments {
            pending.removeFirst()
            pendingSendsBySession[selectedSessionID] = pending.isEmpty ? nil : pending
        }
        let generation = sourceGeneration
        guard generation == sourceGeneration, !Task.isCancelled else { return }
        do {
            inFlightSendsBySession[selectedSessionID] = queued
            try await source.send(
                text: queued.text,
                attachments: queued.attachments.map(\.outbound),
                sessionID: selectedSessionID
            )
            guard generation == sourceGeneration, !Task.isCancelled else { return }
        } catch {
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            inFlightSendsBySession[selectedSessionID] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Requests a fresh response for the latest agent prose by replaying the
    /// exact latest user prompt through the shared send transport. Providers
    /// do not need a special regenerate RPC: the Mac-side source already
    /// binds `send` to the selected Claude, Codex, or OpenCode terminal.
    ///
    /// The transcript remains authoritative. We only mark the action in flight
    /// until the host reports the resulting turn, and leave the existing
    /// response in place so a reconnect or provider rejection cannot erase
    /// useful history.
    func regenerateLatestResponse() async {
        guard let selectedSessionID,
              let source,
              let selectedSession,
              selectedSession.state != .ended,
              !selectedSession.isWorking,
              selectedPendingActionableCount == 0,
              pendingSendsBySession[selectedSessionID, default: []].isEmpty,
              inFlightSendsBySession[selectedSessionID] == nil,
              let baselineResponse = latestAgentResponse(in: selectedSessionID),
              let queued = lastTurnBySession[selectedSessionID],
              latestUserPrompt(in: selectedSessionID) == normalizedPrompt(queued.text),
              regeneratingSessionIDs.insert(selectedSessionID).inserted else { return }
        regenerationBaselineSeqBySession[selectedSessionID] = baselineResponse.seq
        let generation = sourceGeneration
        guard generation == sourceGeneration, !Task.isCancelled else {
            clearRegeneration(for: selectedSessionID)
            return
        }
        do {
            try await source.send(
                text: queued.text,
                attachments: queued.attachments.map(\.outbound),
                sessionID: selectedSessionID
            )
            guard generation == sourceGeneration, !Task.isCancelled else {
                clearRegeneration(for: selectedSessionID)
                return
            }
        } catch {
            guard generation == sourceGeneration, !Task.isCancelled else {
                clearRegeneration(for: selectedSessionID)
                return
            }
            clearRegeneration(for: selectedSessionID)
            errorMessage = error.localizedDescription
        }
    }

    func answer(optionIndex: Int, requestID: String? = nil) async {
        await answer(optionIndexes: [optionIndex], requestID: requestID)
    }

    func answer(optionIndexes: [Int], requestID: String? = nil) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        let requestKey = selectedSessionID + ":" + (requestID ?? "__default__")
        guard !answeringRequestKeys.contains(requestKey),
              !answeredRequestKeysBySession[selectedSessionID, default: []].contains(requestKey)
        else { return }
        answeringRequestKeys.insert(requestKey)
        let generation = sourceGeneration
        defer {
            if generation == sourceGeneration {
                answeringRequestKeys.remove(requestKey)
            }
        }
        guard generation == sourceGeneration, !Task.isCancelled else { return }
        do {
            try await source.answer(optionIndexes: optionIndexes, requestID: requestID, sessionID: selectedSessionID)
            guard generation == sourceGeneration else { return }
            answeredRequestKeysBySession[selectedSessionID, default: []].insert(requestKey)
        } catch {
            guard generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func answer(text: String, requestID: String? = nil) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        let requestKey = selectedSessionID + ":" + (requestID ?? "__default__")
        guard !answeringRequestKeys.contains(requestKey),
              !answeredRequestKeysBySession[selectedSessionID, default: []].contains(requestKey)
        else { return }
        answeringRequestKeys.insert(requestKey)
        let generation = sourceGeneration
        defer {
            if generation == sourceGeneration { answeringRequestKeys.remove(requestKey) }
        }
        guard generation == sourceGeneration, !Task.isCancelled else { return }
        do {
            try await source.answer(text: text, requestID: requestID, sessionID: selectedSessionID)
            guard generation == sourceGeneration else { return }
            answeredRequestKeysBySession[selectedSessionID, default: []].insert(requestKey)
        } catch {
            guard generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func isReviewing(messageID: String) -> Bool {
        guard let selectedSessionID else { return false }
        return reviewingMessageKeys.contains("\(selectedSessionID):\(messageID)")
    }

    /// Sends a provider-neutral review action to the host. The transcript is
    /// intentionally left immutable; a successful host mutation is reflected
    /// by the next authoritative file event or refresh.
    func review(
        messageID: String,
        action: ChatReviewAction,
        filePath: String,
        unifiedDiff: String?,
        lineNumber: Int? = nil,
        comment: String? = nil
    ) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        let key = "\(selectedSessionID):\(messageID)"
        guard reviewingMessageKeys.insert(key).inserted else { return }
        let generation = sourceGeneration
        defer {
            if generation == sourceGeneration { reviewingMessageKeys.remove(key) }
        }
        do {
            try await source.review(
                action: action,
                sessionID: selectedSessionID,
                messageID: messageID,
                filePath: filePath,
                unifiedDiff: unifiedDiff,
                lineNumber: lineNumber,
                comment: comment
            )
            guard generation == sourceGeneration else { return }
            await loadHistory(
                sessionID: selectedSessionID,
                source: source,
                reset: true,
                generation: generation
            )
        } catch {
            guard generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    private func loadAndObserve(source: any AgentChatSessionSource, generation: Int) async {
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        await observeHostEvents(source: source, generation: generation)
    }

    private func observeHostEvents(source: any AgentChatSessionSource, generation: Int) async {
        var reconnectAttempt = 0
        while !Task.isCancelled, generation == sourceGeneration {
            let stream = await source.sessionEvents()
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            connectionState = .connected
            reconnectAttempt = 0
            // Register the stream before taking the authoritative snapshot.
            // The stream has no replay cursor, so listing first leaves a gap
            // in which a state/session event can be lost permanently.
            await loadSessions(source: source, generation: generation)
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            for await frame in stream {
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                // Pushes are delivery hints. A version jump means one or more
                // frames were lost (or arrived on the other event lane), so
                // pull the authoritative descriptor and transcript before
                // folding this frame. Equal revisions are valid for multiple
                // transcript cards and state/descriptor duplicates.
                let didReconcileVersionGap = await reconcileVersionGapIfNeeded(
                    frame,
                    source: source,
                    generation: generation
                )
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                apply(frame.event, to: frame.sessionID, version: frame.version)
                if frame.event.eventIsDescriptorChange, !didReconcileVersionGap {
                    if let descriptor = try? await source.session(sessionID: frame.sessionID) {
                        guard !Task.isCancelled, generation == sourceGeneration else { return }
                        upsert(descriptor)
                    }
                }
            }
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            connectionState = .reconnecting
            reconnectAttempt += 1
            await reconnectDelay(reconnectAttempt)
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            // Reconcile the session snapshot and transcript after an EOF. The
            // stream has no replay cursor, so events published while it was
            // down can only be recovered from the host's authoritative state.
            await loadSessions(source: source, generation: generation)
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            if let selectedSessionID {
                await loadHistory(
                    sessionID: selectedSessionID,
                    source: source,
                    reset: true,
                    generation: generation
                )
            }
        }
    }

    private func loadSessions(source: any AgentChatSessionSource, generation: Int? = nil) async {
        do {
            let loaded = try await source.sessions(workspaceID: nil)
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            let currentByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let reconciled = loaded.compactMap { descriptor -> ChatSessionDescriptor? in
                if let removedVersion = removedSessionVersions[descriptor.id],
                   descriptor.version <= removedVersion {
                    return nil
                }
                // A snapshot can have started before a newer live descriptor
                // event arrived. Keep the newer in-memory value in that case.
                if let current = currentByID[descriptor.id], current.version > descriptor.version {
                    return current
                }
                return descriptor
            }
            for descriptor in reconciled {
                if let removedVersion = removedSessionVersions[descriptor.id],
                   descriptor.version > removedVersion {
                    removedSessionVersions.removeValue(forKey: descriptor.id)
                }
            }
            sessions = reconciled.sorted(by: Self.sortSessions)
            selectPendingLaunchIfAvailable()
            for descriptor in sessions {
                latestVersionBySession[descriptor.id] = max(
                    descriptor.version,
                    latestVersionBySession[descriptor.id] ?? Int.min
                )
            }
            if selectedSessionID == nil, let first = visibleSessions.first {
                select(first)
            } else if let selectedSessionID,
                      !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                if let first = visibleSessions.first {
                    select(first)
                }
            }
            connectionState = .connected
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            connectionState = .reconnecting
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistory(
        sessionID: String,
        source: any AgentChatSessionSource,
        reset: Bool,
        generation: Int? = nil
    ) async {
        guard !loadingSessionIDs.contains(sessionID) else { return }
        loadingSessionIDs.insert(sessionID)
        defer { loadingSessionIDs.remove(sessionID) }
        do {
            var resetRequest = reset
            while true {
                let before = resetRequest ? nil : historyCursors[sessionID]
                let revisionAtStart = transcriptRevisions[sessionID, default: 0]
                let usageRevisionAtStart = usageRevisions[sessionID, default: 0]
                let resetTokenAtStart = historyResetTokens[sessionID, default: 0]
                let page = try await source.history(sessionID: sessionID, beforeSeq: before, limit: 80)
                guard !Task.isCancelled,
                      generation.map({ $0 == sourceGeneration }) ?? true else { return }
                // A removal can race this RPC. The session's transcript was
                // purged in that case, so do not retry the request or restore
                // state for a session that is no longer in the live list.
                guard sessions.contains(where: { $0.id == sessionID }) else { return }

                // A reset can arrive while this RPC is in flight. Re-anchor
                // the request to the new sequence space instead of applying a
                // page from the old transcript over the reset state.
                if resetTokenAtStart != historyResetTokens[sessionID, default: 0] {
                    resetRequest = true
                    continue
                }

                if resetRequest {
                    let current = messagesBySession[sessionID] ?? []
                    if revisionAtStart != transcriptRevisions[sessionID, default: 0] {
                        // Live events delivered during the RPC win over stale
                        // duplicate values from the history response.
                        messagesBySession[sessionID] = mergeMessages(page.messages, current)
                        terminalBlocksBySession[sessionID] = mergeTerminalBlocks(
                            page.terminalBlocks ?? [],
                            terminalBlocksBySession[sessionID] ?? []
                        )
                    } else {
                        messagesBySession[sessionID] = page.messages
                        terminalBlocksBySession[sessionID] = page.terminalBlocks ?? []
                    }
                } else {
                    messagesBySession[sessionID] = mergeMessages(
                        page.messages,
                        messagesBySession[sessionID] ?? []
                    )
                    if let blocks = page.terminalBlocks {
                        terminalBlocksBySession[sessionID] = mergeTerminalBlocks(
                            blocks,
                            terminalBlocksBySession[sessionID] ?? []
                        )
                    }
                }
                if usageRevisionAtStart == usageRevisions[sessionID, default: 0],
                   let usage = page.usage {
                    usageBySession[sessionID] = usage
                } else if resetRequest,
                          usageRevisionAtStart == usageRevisions[sessionID, default: 0] {
                    usageBySession[sessionID] = nil
                }
                reconcilePendingPrompts(sessionID: sessionID)
                seedRetryPromptIfNeeded(sessionID: sessionID)
                historyCursors[sessionID] = page.messages.first?.seq
                // The host can report that older transcript lines exist on
                // disk even when they have fallen outside its bounded cache.
                // An empty page has no cursor to advance, so retaining
                // `hasMore` would make every tap request the newest page
                // again forever.
                historyHasMore[sessionID] = page.hasMore && !page.messages.isEmpty
                break
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ event: ChatSessionEvent, to sessionID: String, version: Int? = nil) {
        if let version {
            // Host pushes are best-effort and can arrive out of order. Equal
            // revisions are valid: one registry mutation may publish a reset,
            // transcript batch, and descriptor/state cards. A lower revision,
            // however, is stale for every event kind; applying it could let a
            // delayed transcript update overwrite newer history or resurrect a
            // streaming preview that a later frame already cleared.
            if let latest = latestVersionBySession[sessionID], version < latest {
                return
            }
            latestVersionBySession[sessionID] = max(
                version,
                latestVersionBySession[sessionID] ?? Int.min
            )
        }
        switch event {
        case .appended(let messages): upsertMessages(messages, sessionID: sessionID)
        case .updated(let messages): upsertMessages(messages, sessionID: sessionID)
        case .streamingProse(let message): streamingBySession[sessionID] = message
        case .stateChanged(let state):
            guard let old = sessions.first(where: { $0.id == sessionID }) else { return }
            // State pushes now carry the same monotonic revision as the
            // descriptor mutation that produced them. Ignore a stale push
            // that arrives after a newer snapshot/descriptor event. Older
            // hosts omit the frame revision and retain the best-effort legacy
            // behavior for compatibility.
            if let version {
                guard version > old.version else { return }
            }
            upsert(old.withState(state, version: version))
            switch state {
            case .working, .needsInput, .failed, .ended:
                clearRegeneration(for: sessionID)
            case .idle:
                // An idle push can race the terminal input acknowledgement;
                // wait for the new response or a non-idle turn state before
                // re-enabling regenerate.
                break
            }
        case .descriptorChanged(let descriptor): upsert(descriptor)
        case .sessionRemoved:
            let version: Int
            if case .sessionRemoved(let removedVersion) = event {
                version = removedVersion
            } else {
                version = Int.max
            }
            if let current = sessions.first(where: { $0.id == sessionID }), version < current.version {
                return
            }
            removedSessionVersions[sessionID] = max(version, removedSessionVersions[sessionID] ?? Int.min)
            sessionTasks[sessionID]?.cancel()
            sessionTasks[sessionID] = nil
            historyReloadTasks[sessionID]?.cancel()
            historyReloadTasks[sessionID] = nil
            sessions.removeAll { $0.id == sessionID }
            controlsBySession[sessionID] = nil
            controlsRequestTokens[sessionID] = nil
            messagesBySession[sessionID] = nil
            terminalBlocksBySession[sessionID] = nil
            usageBySession[sessionID] = nil
            usageRevisions[sessionID] = nil
            streamingBySession[sessionID] = nil
            historyCursors[sessionID] = nil
            historyHasMore[sessionID] = nil
            transcriptRevisions[sessionID] = nil
            historyResetTokens[sessionID] = nil
            latestVersionBySession[sessionID] = max(
                version,
                latestVersionBySession[sessionID] ?? Int.min
            )
            pendingSendsBySession[sessionID] = nil
            inFlightSendsBySession[sessionID] = nil
            lastTurnBySession[sessionID] = nil
            answeredRequestKeysBySession[sessionID] = nil
            answeringRequestKeys = answeringRequestKeys.filter { !$0.hasPrefix("\(sessionID):") }
            reviewingMessageKeys = reviewingMessageKeys.filter { !$0.hasPrefix("\(sessionID):") }
            sendingSessionIDs.remove(sessionID)
            loadingSessionIDs.remove(sessionID)
            updatingControlsSessionIDs.remove(sessionID)
            interruptingSessionIDs.remove(sessionID)
            retryingSessionIDs.remove(sessionID)
            renamingSessionIDs.remove(sessionID)
            deletingSessionIDs.remove(sessionID)
            exportingSessionIDs.remove(sessionID)
            clearRegeneration(for: sessionID)
            if selectedSessionID == sessionID {
                if let next = visibleSessions.first {
                    select(next)
                } else {
                    selectedSessionID = nil
                }
            }
        case .terminalBlocks:
            if case .terminalBlocks(let blocks) = event {
                transcriptRevisions[sessionID, default: 0] &+= 1
                var byID = Dictionary(
                    uniqueKeysWithValues: (terminalBlocksBySession[sessionID] ?? []).map { ($0.id, $0) }
                )
                for block in blocks { byID[block.id] = block }
                terminalBlocksBySession[sessionID] = byID.values.sorted { $0.id < $1.id }
            }
        case .usageChanged(let usage):
            usageBySession[sessionID] = usage
            usageRevisions[sessionID, default: 0] &+= 1
        case .reset:
            transcriptRevisions[sessionID, default: 0] &+= 1
            historyResetTokens[sessionID, default: 0] &+= 1
            answeredRequestKeysBySession[sessionID] = nil
            answeringRequestKeys = answeringRequestKeys.filter { !$0.hasPrefix("\(sessionID):") }
            messagesBySession[sessionID] = []
            terminalBlocksBySession[sessionID] = []
            usageBySession[sessionID] = nil
            usageRevisions[sessionID, default: 0] &+= 1
            streamingBySession[sessionID] = nil
            historyCursors[sessionID] = nil
            historyHasMore[sessionID] = nil
            // A reset replaces the authoritative transcript. Do not let a
            // retry replay a prompt from the conversation that was just
            // discarded; the replacement history will seed the latest user
            // prompt again when it arrives.
            pendingSendsBySession[sessionID] = nil
            inFlightSendsBySession[sessionID] = nil
            sendingSessionIDs.remove(sessionID)
            lastTurnBySession[sessionID] = nil
            clearRegeneration(for: sessionID)
            if selectedSessionID == sessionID, let source {
                let generation = sourceGeneration
                historyReloadTasks[sessionID]?.cancel()
                historyReloadTasks[sessionID] = Task { [weak self] in
                    await self?.loadHistory(
                        sessionID: sessionID,
                        source: source,
                        reset: true,
                        generation: generation
                    )
                }
            }
        case .unknown:
            break
        }
    }

    private func upsertMessages(_ messages: [ChatMessage], sessionID: String) {
        transcriptRevisions[sessionID, default: 0] &+= 1
        var current = messagesBySession[sessionID] ?? []
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for message in messages { byID[message.id] = message }
        current = byID.values.sorted { $0.seq < $1.seq }
        messagesBySession[sessionID] = current
        streamingBySession[sessionID] = nil
        reconcilePendingPrompts(sessionID: sessionID)
        seedRetryPromptIfNeeded(sessionID: sessionID)
        if let baseline = regenerationBaselineSeqBySession[sessionID],
           current.contains(where: { isAgentProse($0) && $0.seq > baseline }) {
            clearRegeneration(for: sessionID)
        }
    }

    private func clearRegeneration(for sessionID: String) {
        regeneratingSessionIDs.remove(sessionID)
        regenerationBaselineSeqBySession[sessionID] = nil
    }

    private func seedRetryPromptIfNeeded(sessionID: String) {
        guard lastTurnBySession[sessionID] == nil,
              let latestPrompt = (messagesBySession[sessionID] ?? [])
                  .filter({ $0.role == .user })
                  .sorted(by: { $0.seq > $1.seq })
                  .compactMap({ message -> String? in
                      guard case .prose(let prose) = message.kind else { return nil }
                      let text = prose.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      return text.isEmpty ? nil : text
                  })
                  .first else { return }
        lastTurnBySession[sessionID] = QueuedSend(text: latestPrompt, attachments: [])
    }

    private func latestAgentResponse(in sessionID: String) -> ChatMessage? {
        let messages = messagesBySession[sessionID] ?? []
        guard let response = messages.last(where: { isAgentProse($0) }),
        let latestPrompt = messages.last(where: { message in
            guard message.role == .user else { return false }
            if case .prose = message.kind { return true }
            return false
        }),
        response.seq > latestPrompt.seq else { return nil }
        return response
    }

    private func isAgentProse(_ message: ChatMessage) -> Bool {
        guard message.role == .agent else { return false }
        if case .prose = message.kind { return true }
        return false
    }

    private func latestUserPrompt(in sessionID: String) -> String? {
        (messagesBySession[sessionID] ?? []).last { message in
            guard message.role == .user else { return false }
            guard case .prose = message.kind else { return false }
            return true
        }.flatMap { message in
            guard case .prose(let prose) = message.kind else { return nil }
            return normalizedPrompt(prose.text)
        }
    }

    private func normalizedPrompt(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reconcilePendingPrompts(sessionID: String) {
        let userPrompts = Set((messagesBySession[sessionID] ?? []).compactMap { message -> String? in
            guard message.role == .user,
                  case .prose(let prose) = message.kind else { return nil }
            return prose.text.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        if let inFlight = inFlightSendsBySession[sessionID],
           userPrompts.contains(inFlight.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            inFlightSendsBySession[sessionID] = nil
        }
    }

    private func upsert(_ descriptor: ChatSessionDescriptor) {
        controlsBySession[descriptor.id] = descriptor.controls
        latestVersionBySession[descriptor.id] = max(
            descriptor.version,
            latestVersionBySession[descriptor.id] ?? Int.min
        )
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            guard descriptor.version >= sessions[index].version else { return }
            sessions[index] = descriptor
        } else {
            if let removedVersion = removedSessionVersions[descriptor.id], descriptor.version <= removedVersion {
                return
            }
            sessions.append(descriptor)
        }
        sessions.sort(by: Self.sortSessions)
        selectPendingLaunchIfAvailable()
    }

    private func selectPendingLaunchIfAvailable() {
        for (parentSessionID, result) in Array(pendingLaunchSelections) {
            guard let candidate = sessions.first(where: { descriptor in
                if let childSessionID = result.sessionID, descriptor.id == childSessionID {
                    return true
                }
                guard let terminalID = result.terminalID else { return false }
                return descriptor.terminalID == terminalID
                    && (result.workspaceID == nil || descriptor.workspaceID == result.workspaceID)
            }) else { continue }
            pendingLaunchSelections.removeValue(forKey: parentSessionID)
            select(candidate)
            break
        }
    }

    /// Reconciles a best-effort push when its revision skips one or more
    /// revisions known to this client. Old hosts may omit the wrapper revision
    /// but descriptor/sessionRemoved carry their own revision, so those remain
    /// gap-detectable for compatibility. A first-ever event for a session is
    /// accepted without a pull because there is no local baseline to compare.
    private func reconcileVersionGapIfNeeded(
        _ frame: ChatSessionEventFrame,
        source: any AgentChatSessionSource,
        generation: Int
    ) async -> Bool {
        guard let incomingVersion = frameRevision(frame),
              incomingVersion < Int.max,
              incomingVersion >= 0 else { return false }
        let sessionID = frame.sessionID
        guard sessions.contains(where: { $0.id == sessionID })
            || removedSessionVersions[sessionID] != nil else { return false }
        let baseline = max(
            latestVersionBySession[sessionID] ?? Int.min,
            removedSessionVersions[sessionID] ?? Int.min
        )
        guard baseline != Int.min, incomingVersion > baseline + 1 else { return false }
        do {
            let descriptor = try await source.session(sessionID: sessionID)
            guard !Task.isCancelled, generation == sourceGeneration else { return false }
            upsert(descriptor)
            if selectedSessionID == sessionID {
                await loadHistory(
                    sessionID: sessionID,
                    source: source,
                    reset: true,
                    generation: generation
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            // The frame may be a final removal raced with the pull. Fold it
            // below; the next reconnect/refresh will retry the authoritative
            // pull if the session remains present.
            return false
        }
    }

    private func frameRevision(_ frame: ChatSessionEventFrame) -> Int? {
        if let version = frame.version { return version }
        switch frame.event {
        case .descriptorChanged(let descriptor): return descriptor.version
        case .sessionRemoved(let version): return version
        default: return nil
        }
    }

    private func drainSendQueue(
        sessionID: String,
        source: any AgentChatSessionSource,
        generation: Int
    ) async {
        guard sendingSessionIDs.insert(sessionID).inserted else { return }
        defer { sendingSessionIDs.remove(sessionID) }

        while let queued = pendingSendsBySession[sessionID]?.first {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            pendingSendsBySession[sessionID]?.removeFirst()
            // A queued prompt is not a turn until it reaches the transport.
            // Record the prompt at this boundary so a failure in the first
            // item of a Queue/Steer burst retries that failed item rather than
            // a later prompt that was still waiting behind it.
            lastTurnBySession[sessionID] = queued
            do {
                inFlightSendsBySession[sessionID] = queued
                try await source.send(
                    text: queued.text,
                    attachments: queued.attachments.map(\.outbound),
                    sessionID: sessionID
                )
            } catch {
                guard generation == sourceGeneration, !Task.isCancelled else { return }
                inFlightSendsBySession[sessionID] = nil
                pendingSendsBySession[sessionID, default: []].insert(queued, at: 0)
                if selectedSessionID == sessionID,
                   draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   attachments.isEmpty {
                    draft = queued.text
                    attachments = queued.attachments
                }
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private static func sortSessions(_ lhs: ChatSessionDescriptor, _ rhs: ChatSessionDescriptor) -> Bool {
        if lhs.state.needsAttention != rhs.state.needsAttention { return lhs.state.needsAttention }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }

    private func mergeMessages(_ page: [ChatMessage], _ current: [ChatMessage]) -> [ChatMessage] {
        var byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
        for message in current { byID[message.id] = message }
        return byID.values.sorted { $0.seq < $1.seq }
    }

    private func mergeTerminalBlocks(
        _ page: [TerminalCommandBlock],
        _ current: [TerminalCommandBlock]
    ) -> [TerminalCommandBlock] {
        var byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
        for block in current { byID[block.id] = block }
        return byID.values.sorted { $0.id < $1.id }
    }

}

private extension ChatSessionEvent {
    var eventIsDescriptorChange: Bool {
        if case .descriptorChanged = self { return true }
        return false
    }
}

private extension ChatSessionDescriptor {
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}
