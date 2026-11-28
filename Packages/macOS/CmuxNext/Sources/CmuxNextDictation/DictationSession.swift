public import Foundation
import CmuxNextWakeups
import os

/// One composer's dictation: permissions, the engine, the transcript and
/// the stop deadline. Everything else (where the text goes, Esc, the
/// button) belongs to the page.
///
/// Idle cost is nothing: the engine, its audio tap and the level stream
/// exist only between a start and the end of that session, and the stop
/// deadline is one ``DemandTimer`` shot. The microphone is released as soon
/// as a stop or cancel reaches the engine.
@MainActor
public final class DictationSession {
    /// The page shows one message for several failures; the log keeps the
    /// engine's own reason. It names a framework error, never what was said.
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "dictation")

    public private(set) var phase: DictationPhase = .idle
    /// Called on every change, on the main actor.
    public var onUpdate: ((DictationUpdate) -> Void)?

    private let authorizer: any DictationAuthorizing
    private let makeTranscriber: @MainActor (DictationAudioLevelMeter) -> any SpeechTranscribing
    private let locale: @MainActor () -> Locale
    private let stopDeadline: Duration
    private let deadline: DemandTimer

    /// Bumped by every start and cancel; work from an older session drops
    /// its results.
    private var generation = 0
    private var transcriber: (any SpeechTranscribing)?
    private var transcript = DictationTranscript()
    /// Every committed segment, uncapped (``DictationTranscript`` keeps only
    /// a tail).
    private var committed = ""
    private var level: Float = 0
    private var listening: Task<Void, Never>?
    private var levels: Task<Void, Never>?

    /// - Parameters:
    ///   - makeTranscriber: A fresh single-session engine fed by the meter.
    ///   - locale: The language, read at each start.
    ///   - stopDeadline: How long a stop may flush before the session ends
    ///     with what it has.
    public init(
        authorizer: any DictationAuthorizing = SystemDictationAuthorizer(),
        makeTranscriber: @escaping @MainActor (DictationAudioLevelMeter) -> any SpeechTranscribing = { meter in
            OnDeviceDictationTranscriber(levelMeter: meter)
        },
        locale: @escaping @MainActor () -> Locale = { Locale.current },
        stopDeadline: Duration = .seconds(3),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.authorizer = authorizer
        self.makeTranscriber = makeTranscriber
        self.locale = locale
        self.stopDeadline = stopDeadline
        deadline = DemandTimer(owner: "dictation.stop", clock: clock)
    }

    /// Starts listening, or stops when a session runs (the mic button).
    public func toggle() {
        if phase.isStartable { start() } else { stop() }
    }

    /// Starts a session. Asks for the microphone the first time; a denied
    /// permission rests in ``DictationPhase/denied(_:)``.
    public func start() {
        guard phase.isStartable else { return }
        generation += 1
        let session = generation
        transcript = DictationTranscript()
        committed = ""
        level = 0
        set(.starting)
        // task-owner: stored in listening; cancel() and the next start supersede it by generation
        listening = Task { [weak self] in await self?.listen(session) }
    }

    /// Stops listening and keeps the text. The engine flushes its last
    /// words first, within ``stopDeadline``. A stop before listening began
    /// is a cancel: nothing was heard.
    public func stop() {
        switch phase {
        case .starting:
            cancel()
        case .listening:
            set(.finalizing)
            let session = generation
            deadline.schedule(after: stopDeadline) { @MainActor [weak self] in
                self?.finish(session)
            }
            finishEngine()
        default:
            break
        }
    }

    /// Ends the session and discards its text (Esc).
    public func cancel() {
        guard !phase.isStartable else { return }
        generation += 1
        deadline.cancel()
        listening?.cancel()
        listening = nil
        endLevels()
        finishEngine()
        transcriber = nil
        phase = .idle
        onUpdate?(DictationUpdate(phase: .idle, cancelled: true))
    }

    /// Anything still held for a session: the engine, its tasks, the stop deadline.
    /// False whenever the phase is startable (tests check nothing leaks).
    public var holdsResources: Bool {
        transcriber != nil || listening != nil || levels != nil || deadline.isScheduled
    }

    private func listen(_ session: Int) async {
        guard await authorizeMicrophone(), session == generation else {
            if session == generation {
                listening = nil
                set(.denied(.microphone))
            }
            return
        }
        let meter = DictationAudioLevelMeter()
        let engine = makeTranscriber(meter)
        transcriber = engine
        let stream: AsyncThrowingStream<DictationTranscriptionEvent, any Error>
        do {
            stream = try await engine.transcribe(locale: locale())
        } catch {
            guard session == generation else { return }
            fail(session, error)
            return
        }
        guard session == generation, phase == .starting else {
            // Cancelled while starting: the engine may have opened the
            // microphone after the cancel reached it.
            await engine.finishTranscribing()
            return
        }
        set(.listening)
        // task-owner: stored in levels; ends with the meter or the session
        levels = Task { [weak self] in
            for await level in meter.levels {
                guard let self, session == self.generation else { return }
                self.level = level
                if self.phase == .listening { self.emit() }
            }
        }
        do {
            for try await event in stream {
                guard session == generation else { return }
                if let delta = transcript.apply(event) { committed += delta }
                emit()
            }
        } catch {
            guard session == generation else { return }
            fail(session, error)
            return
        }
        meter.finish()
        finish(session)
    }

    /// The stream ended or the stop deadline passed: keep what was heard.
    private func finish(_ session: Int) {
        guard session == generation, phase == .listening || phase == .finalizing else { return }
        generation += 1
        deadline.cancel()
        listening?.cancel()
        listening = nil
        endLevels()
        if let delta = transcript.commitTrailingVolatileText() { committed += delta }
        // The engine ended its stream itself (or missed the deadline); make
        // sure it let go of the microphone.
        finishEngine()
        transcriber = nil
        phase = .idle
        onUpdate?(DictationUpdate(phase: .idle, text: committed))
    }

    private func fail(_ session: Int, _ error: any Error) {
        generation += 1
        deadline.cancel()
        listening = nil
        endLevels()
        finishEngine()
        transcriber = nil
        // Keep the words on screen when it fails mid-phrase.
        if let delta = transcript.commitTrailingVolatileText() { committed += delta }
        let failure = error as? DictationFailure ?? .transcriptionFailed(String(describing: error))
        Self.logger.error("dictation failed: \(String(describing: failure), privacy: .public)")
        switch failure {
        case .microphoneAccessDenied: set(.denied(.microphone), text: committed)
        case .speechRecognitionAccessDenied: set(.denied(.speechRecognition), text: committed)
        default: set(.failed(failure), text: committed)
        }
    }

    private func authorizeMicrophone() async -> Bool {
        switch await authorizer.microphoneAuthorization() {
        case .authorized: true
        case .denied: false
        case .undetermined: await authorizer.requestMicrophoneAuthorization()
        }
    }

    /// Stops the engine without waiting: it releases the microphone and
    /// flushes into the stream the run loop is reading.
    private func finishEngine() {
        guard let engine = transcriber else { return }
        // task-owner: one-shot teardown; the engine's finish is idempotent and bounded
        Task { await engine.finishTranscribing() }
    }

    private func endLevels() {
        levels?.cancel()
        levels = nil
        level = 0
    }

    private func set(_ phase: DictationPhase, text: String? = nil) {
        self.phase = phase
        onUpdate?(DictationUpdate(phase: phase, text: text ?? committed + transcript.volatileDelta, level: level))
    }

    private func emit() {
        onUpdate?(DictationUpdate(phase: phase, text: committed + transcript.volatileDelta, level: level))
    }
}
