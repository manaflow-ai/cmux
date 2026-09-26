import Foundation
public import Observation

/// Orchestrates one dictation session: permissions → recognition → insertion.
///
/// `@MainActor @Observable` coordinator (architecture layer 3). Trigger sources
/// call ``toggle()`` (double-tap) or the ``beginHold()``/``endHold()`` pair
/// (push-to-talk). Final transcripts are handed to the injected
/// ``DictationTextSink``; partials are published on ``partialTranscript`` for a
/// HUD.
///
/// The recognition engine is created per attempt through `makeSession`, so
/// tests inject a scripted fake and the real app injects `SpeechDictationEngine`.
@MainActor
@Observable
public final class DictationController {
    /// Lifecycle phase driving HUD presentation.
    public enum Phase: Equatable, Sendable {
        /// No session; ready to start.
        case idle
        /// Authorization resolving, or the audio engine spinning up.
        case requestingPermission
        /// Microphone live and recognition running.
        case listening
        /// Graceful finish in flight, awaiting the final transcript.
        case stopping
        /// Terminal failure (unsupported locale, permission denied). A later
        /// double-tap re-attempts once permissions change.
        case unavailable
    }

    /// The current phase. Drives the HUD.
    public private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            for continuation in phaseContinuations {
                continuation.yield(phase)
            }
        }
    }

    /// Live phase observers. Streams stay open for the controller's lifetime.
    private var phaseContinuations: [AsyncStream<Phase>.Continuation] = []

    /// Observes phase transitions. The current phase yields immediately.
    public func phases() -> AsyncStream<Phase> {
        AsyncStream { continuation in
            continuation.yield(phase)
            phaseContinuations.append(continuation)
        }
    }

    /// Latest interim transcript for the active session; cleared on end.
    public private(set) var partialTranscript: String = ""

    /// Creates a session for a start attempt.
    private let makeSession: @MainActor () -> any DictationRecognizing

    /// Receives finalized transcripts.
    private let sink: any DictationTextSink

    /// How long a graceful finish waits for the final result before a hard
    /// cancel, so the controller cannot hang in ``Phase/stopping``.
    private let finalizeTimeout: Duration

    /// The authorization seam deciding start outcomes.
    private let authorization: DictationAuthorization

    /// The active session, if any.
    private var session: (any DictationRecognizing)?

    /// Consumer task draining the active session's event stream.
    private var consumeTask: Task<Void, Never>?

    /// Watchdog that force-finishes a stuck graceful stop.
    private var watchdog: Task<Void, Never>?

    /// Builds a controller.
    ///
    /// - Parameters:
    ///   - makeSession: Creates one recognition session per attempt.
    ///   - sink: Receives finalized transcripts on the main actor.
    ///   - authorization: Speech + microphone permission seam.
    ///   - finalizeTimeout: Graceful-stop watchdog budget. Defaults to 2.5 s.
    public init(
        makeSession: @escaping @MainActor () -> any DictationRecognizing,
        sink: any DictationTextSink,
        authorization: DictationAuthorization,
        finalizeTimeout: Duration = .seconds(2.5)
    ) {
        self.makeSession = makeSession
        self.sink = sink
        self.authorization = authorization
        self.finalizeTimeout = finalizeTimeout
    }

    /// Double-tap semantics: start when idle, graceful finish when listening,
    /// no-op while a finish is already in flight. Retries a start from
    /// ``Phase/unavailable`` so a permission grant (System Settings) is picked
    /// up on the next attempt without restarting the app.
    public func toggle() {
        switch phase {
        case .idle, .unavailable:
            start()
        case .listening:
            finish()
        case .requestingPermission:
            // A second tap while the first start is settling cancels it.
            cancel()
        case .stopping:
            break
        }
    }

    /// Push-to-talk press: starts a session once the hold threshold fired.
    /// Ignored unless idle (a hold during another phase is inert).
    public func beginHold() {
        guard phase == .idle || phase == .unavailable else { return }
        start()
    }

    /// Push-to-talk release: graceful finish so the tail words are kept.
    public func endHold() {
        guard phase == .listening else {
            if phase == .requestingPermission || phase == .stopping { cancel() }
            return
        }
        finish()
    }

    /// Hard-cancels any session and returns to idle. Safe from any phase.
    public func cancel() {
        watchdog?.cancel()
        watchdog = nil
        let session = self.session
        self.session = nil
        if let session {
            Task { await session.cancel() }
        }
        consumeTask?.cancel()
        consumeTask = nil
        partialTranscript = ""
        phase = .idle
    }

    private func start() {
        guard phase == .idle || phase == .unavailable else { return }
        partialTranscript = ""
        switch authorization.resolve() {
        case .granted:
            phase = .requestingPermission
            Task { await self.beginRecognition() }
        case .denied:
            phase = .unavailable
        case .undetermined:
            phase = .requestingPermission
            let request = authorization.request
            Task { @MainActor in
                let granted = await request()
                guard self.phase == .requestingPermission else { return }
                if granted {
                    await self.beginRecognition()
                } else {
                    self.phase = .unavailable
                }
            }
        }
    }

    private func beginRecognition() async {
        let session = makeSession()
        self.session = session
        let events = await session.start()
        consumeTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
                if self.isSessionConcluded(event) { break }
            }
        }
        // The engine start is enqueued off-main; until it reports ready we stay
        // in requestingPermission. There is no separate ready callback in the
        // event stream (partials imply readiness), so promote on the first event
        // and treat an immediate `.failed` as the start failure.
        phase = .listening
    }

    private func apply(_ event: DictationRecognitionEvent) {
        switch event {
        case .partial(let text):
            phase = .listening
            partialTranscript = text
        case .final(let text):
            partialTranscript = ""
            insert(text)
        case .failed:
            if phase == .stopping || phase == .listening {
                // Retryable runtime failure: settle to idle, not unavailable.
                finishCleanup()
            } else {
                phase = .unavailable
            }
        }
    }

    private func isSessionConcluded(_ event: DictationRecognitionEvent) -> Bool {
        switch event {
        case .final, .failed:
            finishCleanup()
            return true
        case .partial:
            return false
        }
    }

    private func finish() {
        guard phase == .listening else {
            cancel()
            return
        }
        phase = .stopping
        // Stream the buffered tail; the final event (or watchdog) settles.
        let session = self.session
        if let session {
            Task { await session.finish() }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.finalizeTimeout ?? .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.forceFinishAfterTimeout()
        }
    }

    private func forceFinishAfterTimeout() {
        guard phase == .stopping else { return }
        // The latest partial already reached the HUD; keep words by inserting
        // the partial when the recognizer never finalized.
        let fallback = partialTranscript
        partialTranscript = ""
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insert(fallback)
        }
        let session = self.session
        if let session {
            Task { await session.cancel() }
        }
        finishCleanup()
    }

    private func insert(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        _ = sink.insertDictationText(cleaned)
    }

    private func finishCleanup() {
        watchdog?.cancel()
        watchdog = nil
        consumeTask?.cancel()
        consumeTask = nil
        session = nil
        partialTranscript = ""
        if phase != .unavailable {
            phase = .idle
        }
    }
}
