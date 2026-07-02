import CmuxAgentChat
import Foundation

/// Drives the live agent-prose streaming preview for in-flight turns.
///
/// The agent CLIs never write token-level prose to their JSONL transcript, so
/// the only token-grained source of a streaming answer is the rendered terminal
/// screen. While a turn is active this polls a screen snapshot for the hosting
/// surface, extracts the in-progress prose with
/// ``AgentChatProseScreenExtractor``, and pushes it to chat clients as a
/// ``ChatSessionEvent/streamingProse`` preview. The preview is cleared the
/// instant the authoritative JSONL line lands (``authoritativeProseArrived``) or
/// the turn ends (``turnEnded``), so it never duplicates a committed message.
///
/// It stays off the keystroke hot path: a surface is only snapshotted while a
/// chat client is subscribed and a turn is actively streaming for that session.
/// Idle sessions are never polled.
@MainActor
final class AgentChatProseStreamer {
    /// Per-session live-turn bookkeeping.
    private struct ActiveTurn {
        let surfaceID: UUID
        let agentKind: ChatAgentKind
        /// Set once the authoritative prose for this turn has landed; the loop
        /// stops emitting until the next ``turnStarted``.
        var settled: Bool = false
        /// Last preview text pushed, so unchanged snapshots don't re-emit.
        var lastEmitted: String?
    }

    private let extractor = AgentChatProseScreenExtractor()
    private var turns: [String: ActiveTurn] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private let emit: @MainActor (ChatSessionEventFrame) -> Void
    private let snapshot: @MainActor (UUID) -> [String]?
    private let hasSubscribers: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async -> Void

    /// Creates a prose streamer.
    ///
    /// - Parameters:
    ///   - emit: Publishes a wire frame to subscribed chat clients.
    ///   - snapshot: Maps a surface id to its rendered screen rows (top to
    ///     bottom), or `nil` when the surface is gone.
    ///   - hasSubscribers: Whether any chat client is currently listening.
    ///   - now: Clock seam for the preview message timestamp.
    ///   - pollInterval: Snapshot cadence while a turn streams.
    ///   - sleep: Cancellable sleep seam for the poll loop.
    init(
        emit: @escaping @MainActor (ChatSessionEventFrame) -> Void,
        snapshot: @escaping @MainActor (UUID) -> [String]?,
        hasSubscribers: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        pollInterval: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.emit = emit
        self.snapshot = snapshot
        self.hasSubscribers = hasSubscribers
        self.now = now
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// Begins (or re-arms) streaming for a session's in-flight turn.
    ///
    /// - Parameters:
    ///   - sessionID: The chat session.
    ///   - surfaceID: The hosting terminal surface to snapshot.
    ///   - agentKind: Selects the prose extractor's chrome markers.
    func turnStarted(sessionID: String, surfaceID: UUID, agentKind: ChatAgentKind) {
        turns[sessionID] = ActiveTurn(surfaceID: surfaceID, agentKind: agentKind)
        guard tasks[sessionID] == nil else { return }
        tasks[sessionID] = Task { [weak self] in
            await self?.runLoop(sessionID: sessionID)
        }
    }

    /// The authoritative prose for the turn landed; drop the preview and stop
    /// emitting until the next turn (kept distinct from ``turnEnded`` so the
    /// poll loop is reused across a multi-block turn instead of respawned).
    func authoritativeProseArrived(sessionID: String) {
        guard turns[sessionID] != nil else { return }
        turns[sessionID]?.settled = true
        turns[sessionID]?.lastEmitted = nil
        clearPreview(sessionID: sessionID)
    }

    /// Ends streaming for a session: cancels the loop and clears the preview.
    func turnEnded(sessionID: String) {
        tasks[sessionID]?.cancel()
        tasks[sessionID] = nil
        let wasActive = turns[sessionID] != nil
        turns[sessionID] = nil
        if wasActive { clearPreview(sessionID: sessionID) }
    }

    /// Tears down every active stream (app teardown / subscriber loss).
    func stopAll() {
        for sessionID in Array(tasks.keys) { turnEnded(sessionID: sessionID) }
    }

    // MARK: - Internals

    private func runLoop(sessionID: String) async {
        while !Task.isCancelled {
            emitPreviewIfChanged(sessionID: sessionID)
            await sleep(pollInterval)
        }
    }

    private func emitPreviewIfChanged(sessionID: String) {
        guard let turn = turns[sessionID], !turn.settled else { return }
        guard hasSubscribers() else { return }
        guard let lines = snapshot(turn.surfaceID) else { return }
        guard let prose = extractor.extract(lines: lines, agentKind: turn.agentKind) else { return }
        guard prose != turn.lastEmitted else { return }
        turns[sessionID]?.lastEmitted = prose
        emit(ChatSessionEventFrame(sessionID: sessionID, event: .streamingProse(previewMessage(sessionID: sessionID, text: prose))))
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
