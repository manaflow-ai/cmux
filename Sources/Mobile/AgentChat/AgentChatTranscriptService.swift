import CMUXAgentLaunch
import CmuxAgentChat
import CmuxTerminal
import Foundation

/// Retains terminal render/tick notifications only while live prose streaming
/// can consume them. Frame notifications cover visible surfaces; tick
/// notifications cover hidden/background surfaces that receive PTY output
/// without drawing a Metal frame.
@MainActor
private final class AgentChatProseStreamWakeDriver {
    private let streamer: AgentChatProseStreamer
    private let hasSubscribers: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?

    init(
        streamer: AgentChatProseStreamer,
        hasSubscribers: @escaping @MainActor () -> Bool
    ) {
        self.streamer = streamer
        self.hasSubscribers = hasSubscribers
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.streamer.subscribersDidChange()
                self?.refreshDemand(kickIfRetained: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let view = notification.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else {
                    return
                }
                self?.streamer.surfaceDidChange(surfaceID)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.streamer.terminalDidTick()
            }
        })
        refreshDemand(kickIfRetained: true)
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        releaseDemand()
    }

    func refreshDemand(kickIfRetained: Bool = false) {
        let shouldRetainDemand = hasSubscribers() && streamer.hasActiveUnsettledTurns
        if shouldRetainDemand {
            if releaseFrameDemand == nil {
                releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
            }
            if releaseTickDemand == nil {
                releaseTickDemand = GhosttyApp.retainTickNotifications()
            }
            if kickIfRetained {
                streamer.terminalDidTick()
            }
        } else {
            releaseDemand()
        }
    }

    private func releaseDemand() {
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseTickDemand?()
        releaseTickDemand = nil
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseFrameDemand?()
        releaseTickDemand?()
    }
}

enum AgentChatTranscriptTailerOwnership: Sendable, Equatable {
    case mobileSubscriber
    case automaticArtifactCapture
}

/// Mac-side facade for the agent chat surface: tracks sessions from hook
/// events, tails their transcripts, serves history pages, and pushes
/// `chat.message` events to subscribed mobile clients.
@MainActor
final class AgentChatTranscriptService {
    /// The push topic chat clients subscribe to.
    static let eventTopic = "chat.message"
    /// Maximum number of transcript tailers retained solely for automatic
    /// artifact capture. Mobile-owned tailers are demand-driven and are not
    /// counted against this cap.
    static let maxArtifactOnlyTailers = 32
    /// Explicitly opened mobile histories retain a larger but still bounded
    /// watcher/cache pool until demand can be represented per session.
    static let maxMobileSubscriberTailers = 64
    /// Quiet period used to coalesce transcript prose batches before parsing
    /// the full bounded transcript for automatic capture.
    static let artifactCaptureDebounceDelay: Duration = .milliseconds(350)
    nonisolated private static let proseStreamingSnapshotMaxRows = 240

    let registry: AgentChatSessionRegistry
    let resolver: AgentChatTranscriptResolver
    let artifactIndex: AgentChatArtifactIndex
    let artifactGalleryOrderingCache: ChatArtifactGalleryOrderingCache
    let artifactGalleryRowCountCache: ChatArtifactGalleryRowCountCache
    let artifactCaptureCoordinator: AgentArtifactCaptureCoordinator?
    let isAutomaticArtifactCaptureEnabled: @MainActor @Sendable () -> Bool
    var automaticArtifactCaptureWasEnabled: Bool
    var artifactCaptureTasks: [String: (
        token: UUID,
        task: Task<Void, Never>?,
        pending: (@Sendable () async -> Void)?
    )] = [:]
    var tailers: [String: AgentChatTranscriptTailer] = [:]
    var tailerOwnership: [String: AgentChatTranscriptTailerOwnership] = [:]
    var artifactTailerLastUse: [String: UInt64] = [:]
    var mobileTailerLastUse: [String: UInt64] = [:]
    var artifactCaptureDebounceTasks: [String: (
        token: UUID,
        task: Task<Void, Never>
    )] = [:]
    private var artifactTailerUseCounter: UInt64 = 0
    private let artifactCaptureDebounceClock: any Clock<Duration>
    private var eventSubscriptionObserver: NSObjectProtocol?
    let hasEventSubscribers: @MainActor () -> Bool
    private let emitEventPayload: @MainActor ([String: Any]) -> Void
    private let now: () -> Date
    /// Drives the live agent-prose streaming preview.
    private var proseStreamer: AgentChatProseStreamer!
    /// Bridges terminal output/render wakeups into the prose streamer.
    private var proseWakeDriver: AgentChatProseStreamWakeDriver!
    /// Current live prose-stream generation per session, consumed only when a
    /// matching authoritative transcript prose line lands for that turn.
    private var proseTurnStates: [String: ProseTurnState] = [:]
    /// Highest transcript seq observed per session, used to bind live preview
    /// settlement to transcript lines that landed after the prompt started.
    private var latestTranscriptSeqBySessionID: [String: Int] = [:]
    /// Sessions whose transcript could not be resolved cheaply; skipped until
    /// authoritative bindings arrive or an explicit history request retries.
    /// Hook delivery never runs Codex's recursive fallback scan.
    var failedResolutions: Set<String> = []
    private let fallbackResolutionCoordinator: AgentChatFallbackTranscriptResolutionCoordinator
    private var endedListability = AgentChatEndedTranscriptListabilityCache()

    private struct ProseTurnState {
        let token: AgentChatProseStreamer.TurnToken
        let startedAt: Date
        let transcriptFloorSeq: Int
    }

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
        resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver(),
        hasEventSubscribers: @escaping @MainActor () -> Bool = {
            MobileHostService.hasEventSubscribers(topic: AgentChatTranscriptService.eventTopic)
        },
        emitEventPayload: @escaping @MainActor ([String: Any]) -> Void = { payload in
            MobileHostService.emitEvent(topic: AgentChatTranscriptService.eventTopic, payload: payload)
        },
        artifactIndex: AgentChatArtifactIndex = AgentChatArtifactIndex(),
        artifactGalleryOrderingCache: ChatArtifactGalleryOrderingCache = ChatArtifactGalleryOrderingCache(),
        artifactGalleryRowCountCache: ChatArtifactGalleryRowCountCache = ChatArtifactGalleryRowCountCache(maximumAge: 2),
        artifactCaptureCoordinator: AgentArtifactCaptureCoordinator? = nil,
        isAutomaticArtifactCaptureEnabled: @escaping @MainActor @Sendable () -> Bool = { true },
        artifactCaptureDebounceClock: any Clock<Duration> = ContinuousClock(),
        now: @escaping () -> Date = { Date() },
        fallbackTranscriptPathResolver: AgentChatFallbackTranscriptResolutionCoordinator.Resolver? = nil,
        fallbackResolutionTimeout: Duration = .seconds(3)
    ) {
        self.registry = registry
        self.resolver = resolver
        self.hasEventSubscribers = hasEventSubscribers
        self.emitEventPayload = emitEventPayload
        self.artifactIndex = artifactIndex
        self.artifactGalleryOrderingCache = artifactGalleryOrderingCache
        self.artifactGalleryRowCountCache = artifactGalleryRowCountCache
        self.artifactCaptureCoordinator = artifactCaptureCoordinator
        self.isAutomaticArtifactCaptureEnabled = isAutomaticArtifactCaptureEnabled
        self.artifactCaptureDebounceClock = artifactCaptureDebounceClock
        self.automaticArtifactCaptureWasEnabled = artifactCaptureCoordinator != nil && isAutomaticArtifactCaptureEnabled()
        self.now = now
        self.fallbackResolutionCoordinator = AgentChatFallbackTranscriptResolutionCoordinator(
            transcriptResolver: resolver,
            resolver: fallbackTranscriptPathResolver,
            timeout: fallbackResolutionTimeout
        )
        registry.onRecordChanged = { [weak self] record, previous in
            self?.handleRecordChange(record, previous: previous)
        }
        registry.onRecordRemoved = { [weak self] record in
            self?.handleRecordRemoval(record)
        }
        let proseStreamer = AgentChatProseStreamer(
            emit: { [weak self] frame in self?.emit(frame: frame) },
            snapshot: { surfaceID in await Self.screenRows(surfaceID: surfaceID) },
            hasSubscribers: { [weak self] in self?.hasEventSubscribers() ?? false }
        )
        self.proseStreamer = proseStreamer
        self.proseWakeDriver = AgentChatProseStreamWakeDriver(
            streamer: proseStreamer,
            hasSubscribers: { [weak self] in self?.hasEventSubscribers() ?? false }
        )
        self.proseWakeDriver.start()
        self.eventSubscriptionObserver = NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileTranscriptTailerOwnership()
            }
        }
    }

    /// Rendered screen rows (top to bottom) for a surface, the source the prose
    /// streamer scrapes. This intentionally reads the plain viewport text
    /// instead of the mobile render-grid JSON path: live prose streaming only
    /// needs text rows, and grid decoding is owned by the terminal renderer.
    @MainActor
    private static func screenRows(surfaceID: UUID) async -> [String]? {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else {
            return nil
        }
        guard let text = surface.visibleText() else {
            return nil
        }
        return proseStreamingRows(from: text)
    }

    nonisolated private static func proseStreamingRows(from text: String) -> [String] {
        let rows = text.components(separatedBy: .newlines)
        guard rows.count > proseStreamingSnapshotMaxRows else {
            return rows
        }
        return Array(rows.suffix(proseStreamingSnapshotMaxRows))
    }

    /// A cmux-authored resume re-bind buffered until the service is live.
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
    static func isValidResumeSessionID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
        guard isValidResumeSessionID(sessionID) else { return }
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

    /// Seeds the session registry from the on-disk hook stores. Call once at
    /// app startup. Hook events stay authoritative for state and transcripts;
    /// observe-floor scans later add live agent presence even before hooks fire.
    func start() {
        Self.liveInstance = self
        // Apply resume re-binds buffered before the service was wired. The seed
        // only creates records that don't already exist, so an intent applied
        // here is preserved (the seed skips it) and one applied after flips the
        // seeded `.ended` record to `.idle`: either order converges.
        let buffered = Self.pendingResumeIntents
        Self.pendingResumeIntents.removeAll()
        for intent in buffered {
            noteResumeInitiated(
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
        // Tail eagerly while chat delivery or automatic artifact capture needs
        // transcript completion, and never for an ended session (its transcript
        // can no longer grow; recreating the tailer would undo ended-state eviction).
        if record.state != .ended {
            ensureTailerForEagerObservation(for: record)
        }
        // Drive the live prose-streaming preview off the turn lifecycle: a
        // prompt starts the in-flight turn, Stop ends it.
        switch event.hookEventName {
        case .userPromptSubmit:
            if record.state != .ended,
               let surfaceID = record.surfaceID.flatMap(UUID.init(uuidString:)) {
                proseTurnStates[record.sessionID] = ProseTurnState(
                    token: proseStreamer.turnStarted(
                        sessionID: record.sessionID,
                        surfaceID: surfaceID,
                        agentKind: record.agentKind
                    ),
                    startedAt: event.receivedAt,
                    transcriptFloorSeq: latestTranscriptSeqBySessionID[record.sessionID] ?? -1
                )
                proseWakeDriver.refreshDemand(kickIfRetained: true)
            }
        case .stop, .sessionEnd:
            endProseTurn(sessionID: record.sessionID)
            scheduleArtifactCapture(for: record)
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
    /// Awaitable for tests/debug paths that need the updated registry before
    /// proceeding.
    func observeAgentProcesses() async {
        await registry.observeAgentProcesses()
    }

    /// Waits briefly for one coalesced observe-floor scan before a list pull.
    /// Returns false when the scan is still running at the deadline; the caller
    /// can return the current registry snapshot and let the scan push deltas.
    func observeAgentProcessesForListing(surfaceIDs: Set<UUID>?, waitUpTo timeout: Duration) async -> Bool {
        await registry.observeAgentProcessesForListing(surfaceIDs: surfaceIDs, waitUpTo: timeout)
    }

    /// The registry record for a session (send path needs the terminal
    /// binding).
    ///
    /// - Parameter sessionID: Raw session id.
    /// - Returns: The record, or `nil` when unknown.
    func sessionRecord(sessionID: String) -> AgentChatSessionRecord? {
        registry.record(sessionID: sessionID)
    }

    /// Whether an ended session can still serve history without expensive
    /// fallback scans. Live sessions stay visible before their JSONL exists;
    /// ended sessions with missing JSONL only open to an unrecoverable error.
    func hasBoundedReadableTranscript(_ record: AgentChatSessionRecord) -> Bool {
        resolver.boundedTranscriptPath(for: record) != nil
    }

    /// Whether an ended session should remain visible in the list. Claude can be
    /// checked cheaply from cwd/recorded path; Codex fallback scans its sessions
    /// tree, so Codex rows stay listable and resolve fallback history on open.
    func shouldListEndedSession(_ record: AgentChatSessionRecord) -> Bool {
        switch record.agentKind {
        case .codex:
            return true
        case .claude, .other:
            return endedListability.shouldList(record, resolver: resolver, now: now())
        }
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
        let normalizedSessionID = AgentChatSessionRegistry.normalizedSessionID(sessionID, source: source)
        endProseTurn(sessionID: normalizedSessionID)
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
    func history(sessionID: String, beforeSeq: Int?, limit: Int) async -> ChatHistoryPage? {
        guard let record = registry.record(sessionID: sessionID) else { return nil }
        // A user opening the chat is the right moment to retry a previously
        // failed transcript resolution. Codex's recursive fallback is explicit
        // history work, so perform it off the main actor.
        failedResolutions.remove(sessionID)
        let tailer: AgentChatTranscriptTailer
        if let existing = tailers[sessionID] {
            noteTailerUse(
                sessionID: sessionID,
                ownership: .mobileSubscriber
            )
            tailer = existing
        } else {
            let resolver = resolver
            let initialPath = resolver.boundedTranscriptPath(for: record)
            let fallbackPath: String?
            if let initialPath {
                fallbackPath = initialPath
            } else {
                fallbackPath = await fallbackResolutionCoordinator.resolve(for: record)
            }
            guard !Task.isCancelled else { return nil }
            guard let currentRecord = registry.record(sessionID: sessionID) else { return nil }
            failedResolutions.remove(sessionID)
            guard let resolvedTailer = ensureTailer(
                for: currentRecord,
                ownership: .mobileSubscriber,
                resolvePath: {
                    resolver.boundedTranscriptPath(for: currentRecord) ?? fallbackPath
                }
            ) else {
                return nil
            }
            tailer = resolvedTailer
        }
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
    func ensureTailer(for record: AgentChatSessionRecord) -> AgentChatTranscriptTailer? {
        if let existing = tailers[record.sessionID] {
            noteTailerUse(
                sessionID: record.sessionID,
                ownership: .mobileSubscriber
            )
            return existing
        }
        guard !failedResolutions.contains(record.sessionID),
              let boundedPath = resolver.boundedTranscriptPath(for: record) else {
            // Eager observation must not cache a missing bounded path as a
            // failed explicit-history lookup. A later hook can still provide it.
            return nil
        }
        return ensureTailer(
            for: record,
            ownership: .mobileSubscriber
        ) { boundedPath }
    }

    @discardableResult
    func ensureTailer(
        for record: AgentChatSessionRecord,
        ownership: AgentChatTranscriptTailerOwnership,
        resolvePath: () -> String?
    ) -> AgentChatTranscriptTailer? {
        if let existing = tailers[record.sessionID] {
            noteTailerUse(sessionID: record.sessionID, ownership: ownership)
            return existing
        }
        guard ownership == .automaticArtifactCapture
                || !failedResolutions.contains(record.sessionID) else { return nil }
        guard let path = resolvePath() else {
            if ownership == .mobileSubscriber {
                failedResolutions.insert(record.sessionID)
            } else {
                // Eager observation may run before a provider creates its
                // transcript. Do not turn that expected startup gap into a
                // permanent failure; the next hook/flag reconciliation retries.
                failedResolutions.remove(record.sessionID)
            }
            #if DEBUG
            cmuxDebugLog(
                "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
                + "kind=\(record.agentKind.sourceName) cwd=\(record.workingDirectory ?? "nil") UNRESOLVED"
            )
            #endif
            return nil
        }
        failedResolutions.remove(record.sessionID)
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.resolve session=\(record.sessionID.prefix(8)) "
            + "file=\((path as NSString).lastPathComponent)"
        )
        #endif
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
        noteTailerUse(sessionID: sessionID, ownership: ownership)
        enforceArtifactTailerLimit(protectedSessionID: sessionID)
        enforceMobileTailerLimit(protectedSessionID: sessionID)
        if record.transcriptPath != path {
            registry.update(sessionID: record.sessionID) { $0.transcriptPath = path }
        }
        Task { await tailer.start() }
        return tailer
    }

    func publishBatch(_ batch: AgentChatTranscriptTailer.Batch, sessionID: String) {
        if tailerOwnership[sessionID] == .automaticArtifactCapture {
            noteTailerUse(sessionID: sessionID, ownership: .automaticArtifactCapture)
        }
        #if DEBUG
        cmuxDebugLog(
            "agentChat.transcript.batch session=\(sessionID.prefix(8)) "
            + "appended=\(batch.appended.count) updated=\(batch.updated.count) "
            + "reset=\(batch.didReset ? 1 : 0) title=\(batch.discoveredTitle != nil ? 1 : 0)"
        )
        #endif
        if batch.didReset {
            latestTranscriptSeqBySessionID[sessionID] = nil
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .reset))
        }
        if let title = batch.discoveredTitle {
            registry.update(sessionID: sessionID) { $0.title = title }
        }
        if !batch.appended.isEmpty {
            // The authoritative prose for the turn just landed: settle the live
            // preview so the committed message takes over with no duplicate.
            if let turnState = proseTurnStates[sessionID],
               Self.batchContainsAgentProse(batch.appended, matching: turnState) {
                settleProseTurn(sessionID: sessionID, turnState: turnState)
            }
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .appended(batch.appended)))
        }
        if !batch.updated.isEmpty {
            emit(frame: ChatSessionEventFrame(sessionID: sessionID, event: .updated(batch.updated)))
        }
        updateLatestTranscriptSeq(sessionID: sessionID, messages: batch.appended + batch.updated)
        let completedAt = Self.completedAssistantTurnTimestamp(in: batch.appended)
        if let completedAt {
            registry.noteAssistantTurnCompleted(sessionID: sessionID, at: completedAt)
        }
        let containsAuthorizedArtifactMutation = Self.batchContainsAuthorizedArtifactMutation(
            batch.appended + batch.updated
        )
        if completedAt != nil
            || batch.didAuthorizeArtifactMutation
            || containsAuthorizedArtifactMutation,
           let completedRecord = registry.record(sessionID: sessionID) {
            scheduleDebouncedArtifactCapture(for: completedRecord)
        }
    }

    private static func batchContainsAgentProse(_ messages: [ChatMessage], matching turnState: ProseTurnState) -> Bool {
        messages.contains { message in
            guard message.role == .agent else { return false }
            guard case .prose = message.kind else { return false }
            let hasTranscriptTimestamp = message.timestamp > Date(timeIntervalSince1970: 1)
            if hasTranscriptTimestamp {
                return message.timestamp >= turnState.startedAt
            }
            return message.seq > turnState.transcriptFloorSeq
        }
    }

    private func updateLatestTranscriptSeq(sessionID: String, messages: [ChatMessage]) {
        guard let maxSeq = messages.map(\.seq).max() else { return }
        latestTranscriptSeqBySessionID[sessionID] = max(latestTranscriptSeqBySessionID[sessionID] ?? -1, maxSeq)
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

    private static func batchContainsAuthorizedArtifactMutation(
        _ messages: [ChatMessage]
    ) -> Bool {
        messages.contains { message in
            guard message.role == .agent else { return false }
            switch message.kind {
            case .toolUse(let toolUse):
                return toolUse.artifactMutationAuthorized == true
            case .terminal(let terminal):
                guard !terminal.isRunning, terminal.exitCode == 0 else { return false }
                return !ShellArtifactMutationPathDetector()
                    .pathsAttributedToSuccessfulCommand(in: terminal.command)
                    .isEmpty
            case .fileEdit:
                // File-edit cards are emitted before their sidechain result;
                // their visible path is only a reference until the result
                // grants created provenance.
                return false
            case .prose, .thought, .permissionRequest, .question,
                 .status, .attachment, .unsupported:
                return false
            }
        }
    }

    private func handleRecordChange(_ record: AgentChatSessionRecord, previous: AgentChatSessionRecord?) {
        let endedRecordIsListable: Bool
        if record.state == .ended {
            endedRecordIsListable = record.agentKind == .codex
                || endedListability.update(record, previous: previous, resolver: resolver, now: now())
        } else {
            endedListability.remove(sessionID: record.sessionID)
            endedRecordIsListable = true
        }
        let stateChanged = previous?.state != record.state
        let transcriptBecameAvailable = previous?.transcriptPath == nil && record.transcriptPath != nil
        if transcriptBecameAvailable {
            fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
            failedResolutions.remove(record.sessionID)
        }
        if stateChanged, record.state == .ended, previous != nil {
            scheduleArtifactCapture(for: record)
            fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
            // The transcript can no longer grow; stop any live preview loop so
            // an agent that exits without a Stop hook doesn't leak the poll task.
            endProseTurn(sessionID: record.sessionID)
            // The transcript can no longer grow; release the file watcher,
            // cache, ownership, and LRU entry instead of holding them until
            // app quit. Evicting only on the TRANSITION keeps unrelated record
            // updates (title discovery while paging an ended session) from
            // churning it.
            removeTailer(sessionID: record.sessionID)
        }
        if transcriptBecameAvailable, record.state != .ended {
            ensureTailerForEagerObservation(for: record)
        }
        guard hasEventSubscribers() else { return }
        if record.state == .ended, !endedRecordIsListable {
            emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .sessionRemoved(version: record.version)))
            return
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

    private func handleRecordRemoval(_ record: AgentChatSessionRecord) {
        fallbackResolutionCoordinator.cancel(sessionID: record.sessionID)
        endProseTurn(sessionID: record.sessionID)
        removeArtifactCaptureSession(sessionID: record.sessionID)
        Task { await artifactGalleryOrderingCache.remove(indexID: record.sessionID) }
        latestTranscriptSeqBySessionID[record.sessionID] = nil
        removeTailer(sessionID: record.sessionID)
        failedResolutions.remove(record.sessionID)
        endedListability.remove(sessionID: record.sessionID)
        guard hasEventSubscribers() else { return }
        emit(frame: ChatSessionEventFrame(sessionID: record.sessionID, event: .sessionRemoved(version: record.version)))
    }

    private func emit(frame: ChatSessionEventFrame) {
        guard let payload = wirePayload(frame) else { return }
        emitEventPayload(payload)
    }

    private func settleProseTurn(sessionID: String, turnState: ProseTurnState) {
        guard proseTurnStates[sessionID]?.token == turnState.token else { return }
        proseTurnStates[sessionID] = nil
        proseStreamer.authoritativeProseArrived(turnState.token)
        proseWakeDriver.refreshDemand()
    }

    private func endProseTurn(sessionID: String) {
        proseTurnStates[sessionID] = nil
        proseStreamer.turnEnded(sessionID: sessionID)
        proseWakeDriver.refreshDemand()
    }

    deinit {
        // This app-owned service is created and released on the main actor.
        // `isolated deinit` still has Xcode compatibility constraints in cmux,
        // so keep teardown synchronous while asserting that owner invariant.
        MainActor.assumeIsolated {
            if let eventSubscriptionObserver {
                NotificationCenter.default.removeObserver(eventSubscriptionObserver)
            }
            artifactCaptureTasks.values.compactMap(\.task).forEach { $0.cancel() }
            artifactCaptureTasks.removeAll()
            artifactCaptureDebounceTasks.values.forEach { $0.task.cancel() }
            artifactCaptureDebounceTasks.removeAll()
            proseWakeDriver?.stop()
            proseStreamer?.stopAll()
        }
    }
}
