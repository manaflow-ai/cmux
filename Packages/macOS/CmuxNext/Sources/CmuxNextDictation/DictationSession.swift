public import CmuxNextWakeups
public import Foundation
import os

/// One composer's dictation: permissions, the engine, the transcript and
/// the stop deadline. Everything else (where the text goes, Esc, the
/// button) belongs to the page.
///
/// Idle cost is nothing: the engine, its audio tap and the level stream
/// exist only between a start and the end of that session, and the stop
/// deadline is one `MainDeadline` shot. The microphone is released as soon
/// as a stop or cancel reaches the engine.
///
/// The engine's streams are read off main, and each event lands on the
/// session as one posted task on the app's `MainWorkScheduler` (Chrome's
/// PostTaskAndReplyWithResult, base/task/thread_pool.h): the words and the
/// session's end are `userBlocking` (the rest of the person's dictation), the
/// level meter `visible`. One class keeps the words, a failure and the end in
/// the order the engine sent them.
@MainActor
public final class DictationSession {
    /// The page shows one message for several failures; the log keeps the
    /// engine's own reason. It names a framework error, never what was said.
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "dictation")

    public private(set) var phase: DictationPhase = .idle
    /// Keep each session's audio and hand it over with the session's last
    /// update (``DictationUpdate/audio``): the pane's harness takes voice
    /// input. Read at each start.
    public var recordsAudio = false
    /// Called on every change, on the main actor.
    public var onUpdate: ((DictationUpdate) -> Void)?

    private let authorizer: any DictationAuthorizing
    private let makeTranscriber: @MainActor (DictationAudioLevelMeter) -> any SpeechTranscribing
    private let locale: @MainActor () -> Locale
    private let stopDeadline: Duration
    private let deadline: MainDeadline
    /// Where the engine's events land.
    private let work: MainWorkScheduler

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
    /// This session's audio, when ``recordsAudio`` was on at its start.
    private var recording: DictationAudioRecording?

    /// A started engine: its event stream and the meter its audio tap feeds.
    private struct Opened: Sendable {
        let stream: AsyncThrowingStream<DictationTranscriptionEvent, any Error>
        let meter: DictationAudioLevelMeter
    }

    /// - Parameters:
    ///   - deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`): the stop deadline is placed
    ///     on it, and the engine's events land on its `MainWorkScheduler`.
    ///   - makeTranscriber: A fresh single-session engine fed by the meter.
    ///   - locale: The language, read at each start.
    ///   - stopDeadline: How long a stop may flush before the session ends
    ///     with what it has.
    public init(
        deadlines: MainDeadlineScheduler,
        authorizer: any DictationAuthorizing = SystemDictationAuthorizer(),
        makeTranscriber: @escaping @MainActor (DictationAudioLevelMeter) -> any SpeechTranscribing = { meter in
            OnDeviceDictationTranscriber(levelMeter: meter)
        },
        locale: @escaping @MainActor () -> Locale = { Locale.current },
        stopDeadline: Duration = .seconds(3)
    ) {
        self.authorizer = authorizer
        self.makeTranscriber = makeTranscriber
        self.locale = locale
        self.stopDeadline = stopDeadline
        work = deadlines.work
        // userBlocking: the person waits for their stop to end the session with what was heard.
        deadline = MainDeadline(owner: "dictation.stop", workClass: .userBlocking, scheduler: deadlines)
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
        recording = recordsAudio ? DictationAudioRecording() : nil
        set(.starting)
        let work = self.work
        // task-owner: stored in listening; cancel() and the next start supersede it by generation
        listening = Task { @concurrent [weak self] in
            guard let opened = await self?.open(session) else { return }
            do {
                for try await event in opened.stream {
                    work.postFromAnyThread(.userBlocking, owner: "dictation.heard") { [weak self] in self?.heard(event, session) }
                }
            } catch {
                let failure = DictationSession.failure(from: error)
                work.postFromAnyThread(.userBlocking, owner: "dictation.failed") { [weak self] in self?.fail(session, failure) }
                return
            }
            opened.meter.finish()
            work.postFromAnyThread(.userBlocking, owner: "dictation.ended") { [weak self] in self?.finish(session) }
        }
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
            deadline.schedule(after: stopDeadline) { [weak self] in
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
        recording = nil
        phase = .idle
        onUpdate?(DictationUpdate(phase: .idle, cancelled: true))
    }

    /// Anything still held for a session: the engine, its tasks, the stop deadline.
    /// False whenever the phase is startable (tests check nothing leaks).
    public var holdsResources: Bool {
        transcriber != nil || listening != nil || levels != nil || recording != nil || deadline.isScheduled
    }

    /// The session's steps on main up to listening: the permission, the engine and its stream, the level meter.
    /// Nil when the session ended here (denied, failed, or cancelled meanwhile).
    private func open(_ session: Int) async -> Opened? {
        guard await authorizeMicrophone(), session == generation else {
            if session == generation {
                listening = nil
                recording = nil
                set(.denied(.microphone))
            }
            return nil
        }
        let meter = DictationAudioLevelMeter(recording: recording)
        let engine = makeTranscriber(meter)
        transcriber = engine
        let stream: AsyncThrowingStream<DictationTranscriptionEvent, any Error>
        do {
            stream = try await engine.transcribe(locale: locale())
        } catch {
            fail(session, Self.failure(from: error))
            return nil
        }
        guard session == generation, phase == .starting else {
            // Cancelled while starting: the engine may have opened the
            // microphone after the cancel reached it.
            await engine.finishTranscribing()
            return nil
        }
        set(.listening)
        startLevels(meter, session)
        return Opened(stream: stream, meter: meter)
    }

    /// Reads the meter's levels off main; each lands as one visible task (the meter on screen).
    private func startLevels(_ meter: DictationAudioLevelMeter, _ session: Int) {
        let work = self.work
        // task-owner: stored in levels; ends with the meter or the session
        levels = Task { @concurrent [weak self] in
            for await level in meter.levels {
                guard self != nil else { return }
                work.postFromAnyThread(.visible, owner: "dictation.level") { [weak self] in self?.heard(level: level, session) }
            }
        }
    }

    /// One engine event of `session`.
    private func heard(_ event: DictationTranscriptionEvent, _ session: Int) {
        guard session == generation else { return }
        if let delta = transcript.apply(event) { committed += delta }
        emit()
    }

    /// One meter level of `session`.
    private func heard(level: Float, _ session: Int) {
        guard session == generation else { return }
        self.level = level
        if phase == .listening { emit() }
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
        let audio = recording?.wav()
        let omitted = recording?.omission
        recording = nil
        phase = .idle
        onUpdate?(DictationUpdate(phase: .idle, text: committed, audio: audio, audioOmitted: omitted))
    }

    /// The engine of `session` failed: keep the words heard so far.
    private func fail(_ session: Int, _ failure: DictationFailure) {
        guard session == generation else { return }
        generation += 1
        deadline.cancel()
        listening = nil
        endLevels()
        finishEngine()
        transcriber = nil
        recording = nil
        // Keep the words on screen when it fails mid-phrase.
        if let delta = transcript.commitTrailingVolatileText() { committed += delta }
        Self.logger.error("dictation failed: \(String(describing: failure), privacy: .public)")
        switch failure {
        case .microphoneAccessDenied: set(.denied(.microphone), text: committed)
        case .speechRecognitionAccessDenied: set(.denied(.speechRecognition), text: committed)
        default: set(.failed(failure), text: committed)
        }
    }

    /// The engine's error as the session's failure.
    private nonisolated static func failure(from error: any Error) -> DictationFailure {
        error as? DictationFailure ?? .transcriptionFailed(String(describing: error))
    }

    private func authorizeMicrophone() async -> Bool {
        switch await authorizer.microphoneAuthorization() {
        case .authorized: true
        case .denied: false
        case .undetermined: await authorizer.requestMicrophoneAuthorization()
        }
    }

    /// Stops the engine without waiting: it releases the microphone and
    /// flushes into the stream the listening task is reading.
    private func finishEngine() {
        guard let engine = transcriber else { return }
        // task-owner: one-shot teardown; the engine's finish is idempotent and bounded, and runs off main
        Task { @concurrent in await engine.finishTranscribing() }
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
