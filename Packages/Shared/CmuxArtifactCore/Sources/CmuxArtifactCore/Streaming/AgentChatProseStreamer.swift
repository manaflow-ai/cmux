import Foundation

/// Drives the live agent-prose streaming preview for in-flight turns.
///
/// The agent CLIs never write token-level prose to their JSONL transcript, so
/// the only token-grained source of a streaming answer is the rendered terminal
/// screen. While a turn is active this consumes terminal output/render wakeups,
/// snapshots the hosting surface at most once per coalesced wakeup, extracts the
/// in-progress prose with ``AgentChatProseScreenExtractor``, and pushes it to
/// chat clients as a ``ChatSessionEvent/streamingProse`` preview. The preview is
/// cleared the instant the authoritative JSONL line lands
/// (``authoritativeProseArrived``) or the turn ends (``turnEnded``), so it never
/// duplicates a committed message.
///
/// It stays off the keystroke hot path: a surface is only snapshotted when a
/// chat client is subscribed, a turn is actively streaming for that session, and
/// the terminal reports new output/render work. Idle sessions are never polled.
private actor AgentChatProseExtractionWorker {
    private let extractor = AgentChatProseScreenExtractor()

    func extract(lines: [String], agentKind: ChatAgentKind) -> String? {
        extractor.extract(lines: lines, agentKind: agentKind)
    }
}

@MainActor
public final class AgentChatProseStreamer {
    /// Identifies one live prose-streaming generation for a chat session.
    ///
    /// Callers receive this from ``turnStarted(sessionID:surfaceID:agentKind:)``
    /// and must pass the same token back to ``authoritativeProseArrived(_:)``.
    /// A token from an earlier generation is intentionally ignored after the
    /// session resumes, rebinds to another surface, or starts a newer turn.
    public struct TurnToken: Equatable, Sendable {
        fileprivate let sessionID: String
        fileprivate let generation: Int

        fileprivate init(sessionID: String, generation: Int) {
            self.sessionID = sessionID
            self.generation = generation
        }
    }

    /// Per-session live-turn bookkeeping.
    private struct ActiveTurn {
        let generation: Int
        let surfaceID: UUID
        let agentKind: ChatAgentKind
        /// Set once the authoritative prose for this turn has landed; wakeups
        /// stop emitting until the next ``turnStarted``.
        var settled: Bool = false
        /// Last preview text pushed, so unchanged snapshots don't re-emit.
        var lastEmitted: String?
    }

    private let extractionWorker = AgentChatProseExtractionWorker()
    private var turns: [String: ActiveTurn] = [:]
    private var nextGenerationBySessionID: [String: Int] = [:]
    private var activeUnsettledTurnCount = 0
    private var unsettledSessionIDsBySurfaceID: [UUID: Set<String>] = [:]
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalWakeup = false
    private var isFlushScheduled = false
    private var isFlushRunning = false
    private var flushTask: Task<Void, Never>?

    private let emit: @MainActor (ChatSessionEventFrame) -> Void
    private let snapshot: @MainActor (UUID) async -> [String]?
    private let hasSubscribers: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    /// Creates a prose streamer.
    ///
    /// - Parameters:
    ///   - emit: Publishes a wire frame to subscribed chat clients.
    ///   - snapshot: Maps a surface id to its rendered screen rows (top to
    ///     bottom), or `nil` when the surface is gone.
    ///   - hasSubscribers: Whether any chat client is currently listening.
    ///   - now: Clock seam for the preview message timestamp.
    public init(
        emit: @escaping @MainActor (ChatSessionEventFrame) -> Void,
        snapshot: @escaping @MainActor (UUID) async -> [String]?,
        hasSubscribers: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.emit = emit
        self.snapshot = snapshot
        self.hasSubscribers = hasSubscribers
        self.now = now
    }

    /// Whether at least one unsettled turn can currently consume terminal
    /// wakeups. Owners use this to retain and release upstream render/tick
    /// notification demand.
    public var hasActiveUnsettledTurns: Bool {
        activeUnsettledTurnCount > 0
    }

    /// Begins (or re-arms) streaming for a session's in-flight turn.
    ///
    /// - Parameters:
    ///   - sessionID: The chat session.
    ///   - surfaceID: The hosting terminal surface to snapshot.
    ///   - agentKind: Selects the prose extractor's chrome markers.
    /// - Returns: An opaque token for settling this exact turn generation.
    @discardableResult
    public func turnStarted(sessionID: String, surfaceID: UUID, agentKind: ChatAgentKind) -> TurnToken {
        let previous = turns[sessionID]
        let generation = nextGenerationBySessionID[sessionID] ?? 0
        nextGenerationBySessionID[sessionID] = generation + 1
        if let previous, !previous.settled {
            unregisterUnsettledTurn(sessionID: sessionID, surfaceID: previous.surfaceID)
        }
        turns[sessionID] = ActiveTurn(generation: generation, surfaceID: surfaceID, agentKind: agentKind)
        registerUnsettledTurn(sessionID: sessionID, surfaceID: surfaceID)
        if previous?.lastEmitted != nil {
            clearPreview(sessionID: sessionID)
        }
        return TurnToken(sessionID: sessionID, generation: generation)
    }

    /// Signals that the rendered terminal for one surface changed. Multiple
    /// wakeups for the same surface coalesce into one newest-value snapshot.
    public func surfaceDidChange(_ surfaceID: UUID) {
        guard hasSubscribers(),
              unsettledSessionIDsBySurfaceID[surfaceID]?.isEmpty == false else {
            return
        }
        pendingSurfaceIDs.insert(surfaceID)
        scheduleFlush()
    }

    /// Signals a global Ghostty tick. Tick wakeups keep hidden/background
    /// surfaces live because they fire on IO cycles even when no frame renders.
    public func terminalDidTick() {
        guard hasSubscribers(), hasActiveUnsettledTurns else { return }
        hasPendingGlobalWakeup = true
        scheduleFlush()
    }

    /// A chat client subscribed or unsubscribed. Invalidate the shared preview
    /// cache so a newly subscribed client receives the latest unchanged prose.
    public func subscribersDidChange() {
        guard hasSubscribers(), hasActiveUnsettledTurns else { return }
        for sessionID in turns.keys where turns[sessionID]?.settled == false {
            turns[sessionID]?.lastEmitted = nil
        }
        terminalDidTick()
    }

    /// The authoritative prose for the turn landed; drop the preview and stop
    /// emitting until the next turn.
    ///
    /// - Parameter token: The token returned by ``turnStarted`` for the turn
    ///   whose authoritative transcript prose just arrived.
    public func authoritativeProseArrived(_ token: TurnToken) {
        guard let turn = turns[token.sessionID],
              turn.generation == token.generation else { return }
        let hadPreview = turn.lastEmitted != nil
        if !turn.settled {
            unregisterUnsettledTurn(sessionID: token.sessionID, surfaceID: turn.surfaceID)
        }
        turns[token.sessionID]?.settled = true
        turns[token.sessionID]?.lastEmitted = nil
        removePendingWork(sessionID: token.sessionID, turn: turn)
        if hadPreview {
            clearPreview(sessionID: token.sessionID)
        }
    }

    /// Ends streaming for a session: cancels the loop and clears the preview.
    public func turnEnded(sessionID: String) {
        let turn = turns[sessionID]
        let wasActive = turn != nil
        if let turn, !turn.settled {
            unregisterUnsettledTurn(sessionID: sessionID, surfaceID: turn.surfaceID)
        }
        turns[sessionID] = nil
        if let turn {
            removePendingWork(sessionID: sessionID, turn: turn)
        }
        if wasActive, turn?.lastEmitted != nil {
            clearPreview(sessionID: sessionID)
        }
    }

    /// Tears down every active stream (app teardown / subscriber loss).
    public func stopAll() {
        for sessionID in Array(turns.keys) { turnEnded(sessionID: sessionID) }
        activeUnsettledTurnCount = 0
        unsettledSessionIDsBySurfaceID.removeAll()
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalWakeup = false
        cancelFlushTask()
    }

    // MARK: - Internals

    private struct FlushTarget {
        let sessionID: String
        let generation: Int
        let surfaceID: UUID
        let agentKind: ChatAgentKind
    }

    private func scheduleFlush() {
        guard !isFlushScheduled, !isFlushRunning else { return }
        isFlushScheduled = true
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flushPendingChanges()
        }
    }

    private func flushPendingChanges() async {
        isFlushScheduled = false
        isFlushRunning = true
        defer {
            isFlushRunning = false
            flushTask = nil
            if hasActiveUnsettledTurns, hasSubscribers(),
               hasPendingGlobalWakeup || !pendingSurfaceIDs.isEmpty {
                scheduleFlush()
            }
        }

        guard !Task.isCancelled else { return }
        let targets = drainFlushTargets()
        for target in targets {
            guard !Task.isCancelled else { return }
            await emitPreviewIfChanged(target)
        }
    }

    private func drainFlushTargets() -> [FlushTarget] {
        let shouldFlushAll = hasPendingGlobalWakeup
        let surfaceIDs = pendingSurfaceIDs
        hasPendingGlobalWakeup = false
        pendingSurfaceIDs.removeAll()

        guard hasSubscribers() else { return [] }
        var sessionIDs = Set<String>()
        if shouldFlushAll {
            for surfaceSessionIDs in unsettledSessionIDsBySurfaceID.values {
                sessionIDs.formUnion(surfaceSessionIDs)
            }
        } else {
            for surfaceID in surfaceIDs {
                if let surfaceSessionIDs = unsettledSessionIDsBySurfaceID[surfaceID] {
                    sessionIDs.formUnion(surfaceSessionIDs)
                }
            }
        }
        return sessionIDs.compactMap { sessionID in
            guard let turn = turns[sessionID] else { return nil }
            guard !turn.settled else { return nil }
            return FlushTarget(
                sessionID: sessionID,
                generation: turn.generation,
                surfaceID: turn.surfaceID,
                agentKind: turn.agentKind
            )
        }
    }

    private func emitPreviewIfChanged(_ target: FlushTarget) async {
        guard let turn = turns[target.sessionID],
              turn.generation == target.generation,
              !turn.settled,
              hasSubscribers() else { return }
        guard let lines = await snapshot(target.surfaceID) else {
            clearPreviewIfCurrent(target)
            return
        }
        guard !Task.isCancelled else { return }
        guard let prose = await extractionWorker.extract(lines: lines, agentKind: target.agentKind) else {
            clearPreviewIfCurrent(target)
            return
        }
        guard !Task.isCancelled else { return }
        guard let current = turns[target.sessionID],
              current.generation == target.generation,
              !current.settled,
              hasSubscribers() else { return }
        guard prose != current.lastEmitted else { return }
        turns[target.sessionID]?.lastEmitted = prose
        emit(ChatSessionEventFrame(
            sessionID: target.sessionID,
            event: .streamingProse(previewMessage(sessionID: target.sessionID, text: prose))
        ))
    }

    private func clearPreviewIfCurrent(_ target: FlushTarget) {
        guard let current = turns[target.sessionID],
              current.generation == target.generation,
              !current.settled,
              hasSubscribers(),
              current.lastEmitted != nil else { return }
        turns[target.sessionID]?.lastEmitted = nil
        clearPreview(sessionID: target.sessionID)
    }

    private func removePendingWork(sessionID: String, turn: ActiveTurn) {
        if unsettledSessionIDsBySurfaceID[turn.surfaceID]?.isEmpty != false {
            pendingSurfaceIDs.remove(turn.surfaceID)
        }
        if !hasActiveUnsettledTurns {
            hasPendingGlobalWakeup = false
            cancelFlushTask()
        }
    }

    private func registerUnsettledTurn(sessionID: String, surfaceID: UUID) {
        var sessionIDs = unsettledSessionIDsBySurfaceID[surfaceID] ?? []
        if sessionIDs.insert(sessionID).inserted {
            activeUnsettledTurnCount += 1
        }
        unsettledSessionIDsBySurfaceID[surfaceID] = sessionIDs
    }

    private func unregisterUnsettledTurn(sessionID: String, surfaceID: UUID) {
        guard var sessionIDs = unsettledSessionIDsBySurfaceID[surfaceID] else { return }
        if sessionIDs.remove(sessionID) != nil {
            activeUnsettledTurnCount = max(0, activeUnsettledTurnCount - 1)
        }
        if sessionIDs.isEmpty {
            unsettledSessionIDsBySurfaceID.removeValue(forKey: surfaceID)
        } else {
            unsettledSessionIDsBySurfaceID[surfaceID] = sessionIDs
        }
    }

    private func cancelFlushTask() {
        flushTask?.cancel()
        flushTask = nil
        isFlushScheduled = false
    }

    private func clearPreview(sessionID: String) {
        emit(ChatSessionEventFrame(sessionID: sessionID, event: .streamingProse(nil)))
    }

    /// Builds the preview message. The id is stable per session so successive
    /// previews replace in place; the seq sorts it after the committed window.
    private func previewMessage(sessionID: String, text: String) -> ChatMessage {
        ChatMessage(
            id: "stream:\(sessionID)",
            seq: Int.max - 1,
            role: .agent,
            timestamp: now(),
            kind: .prose(ChatProse(text: text))
        )
    }
}
