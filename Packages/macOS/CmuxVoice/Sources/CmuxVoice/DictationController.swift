public import Foundation
import Observation

/// Owns the lifecycle of voice-dictation sessions.
///
/// One controller lives for the app's lifetime. ``toggle()`` starts a
/// session when idle and stops the active one otherwise, walking
/// ``DictationPhase`` in order: authorization → target pinning →
/// transcriber startup → streaming → flush. Volatile partials only update
/// ``transcript`` (for the HUD); finalized segments are typed into the
/// injected ``DictationTextInserting`` target.
///
/// Every dependency is injected, so the full state machine is testable
/// with fakes and no microphone:
///
/// ```swift
/// let controller = DictationController(
///     authorizer: FakeAuthorizer(),
///     inserter: RecordingInserter(),
///     makeTranscriber: { ScriptedTranscriber(events: [.final("hi")]) },
///     localeProvider: { Locale(identifier: "en_US") }
/// )
/// controller.toggle()
/// ```
@MainActor
@Observable
public final class DictationController {
    /// The current lifecycle phase. Drives the HUD.
    public private(set) var phase: DictationPhase = .idle

    /// Live transcript for the active session. Drives the HUD text.
    public private(set) var transcript = DictationTranscript()

    /// Invoked on session failure so the host app can present recovery UI
    /// (for example a "grant access in System Settings" alert).
    public var failureHandler: (@MainActor (DictationFailure) -> Void)?

    private let authorizer: any DictationAuthorizing
    private let inserter: any DictationTextInserting
    private let makeTranscriber: @MainActor () -> any SpeechTranscribing
    private let localeProvider: @MainActor () -> Locale
    private let clock: any Clock<Duration>
    private var activeTranscriber: (any SpeechTranscribing)?
    private var sessionTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var stopRecoveryTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var insertionSessionActive = false

    /// Bounds recovery from a transcriber that never completes its final flush.
    /// This is a user-visible shutdown deadline, not a polling interval.
    private static let stopRecoveryTimeout: Duration = .seconds(3)

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - authorizer: Permission checker/requester.
    ///   - inserter: Router that pins a focus target per session and types
    ///     finalized text into it.
    ///   - makeTranscriber: Factory producing a fresh engine per session.
    ///   - localeProvider: Supplies the dictation language at session start
    ///     (read from settings each time, so changes apply immediately).
    ///   - clock: Clock used for the bounded stop-recovery deadline. Defaults
    ///     to `ContinuousClock`; tests can inject a virtual clock.
    public init(
        authorizer: any DictationAuthorizing,
        inserter: any DictationTextInserting,
        makeTranscriber: @escaping @MainActor () -> any SpeechTranscribing,
        localeProvider: @escaping @MainActor () -> Locale,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.authorizer = authorizer
        self.inserter = inserter
        self.makeTranscriber = makeTranscriber
        self.localeProvider = localeProvider
        self.clock = clock
    }

    /// Whether a session is running (any phase other than the resting
    /// ``DictationPhase/idle`` / ``DictationPhase/failed(_:)`` states).
    public var isActive: Bool {
        switch phase {
        case .idle, .failed: return false
        case .requestingAuthorization, .preparing, .listening, .stopping: return true
        }
    }

    /// Starts a session when resting, stops the active one otherwise.
    public func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    /// Starts a new session. No-op while one is active.
    public func start() {
        guard !isActive else { return }
        finishTask?.cancel()
        finishTask = nil
        stopRecoveryTask?.cancel()
        stopRecoveryTask = nil
        sessionGeneration += 1
        let generation = sessionGeneration
        phase = .requestingAuthorization
        transcript = DictationTranscript()
        sessionTask = Task { [weak self] in
            await self?.runSession(generation: generation)
        }
    }

    /// Asks the active session to finish. Finalized text still in the
    /// engine is flushed and inserted before the session ends.
    public func stop() {
        guard isActive, phase != .stopping else { return }
        let phaseAtStop = phase
        phase = .stopping
        if phaseAtStop == .requestingAuthorization || phaseAtStop == .preparing {
            // Cancellation is limited to startup: cancelling the streaming
            // task after listening begins would skip the engine's final
            // hypothesis instead of letting finishTranscribing flush it.
            sessionTask?.cancel()
        }
        requestFinish(for: sessionGeneration)
        armStopRecovery(for: sessionGeneration)
    }

    private func runSession(generation: Int) async {
        do {
            try Task.checkCancellation()
            guard await authorizeMicrophone() else {
                fail(.microphoneAccessDenied, generation: generation)
                return
            }
            try Task.checkCancellation()
            guard await authorizeSpeechRecognition() else {
                fail(.speechRecognitionAccessDenied, generation: generation)
                return
            }
            try Task.checkCancellation()
            guard sessionGeneration == generation, phase == .requestingAuthorization else {
                // Stopped (or superseded) while a permission prompt was up.
                settle(generation: generation)
                return
            }
            guard await inserter.beginSession() else {
                guard !Task.isCancelled else {
                    settle(generation: generation)
                    return
                }
                fail(.insertionTargetUnavailable, generation: generation)
                return
            }
            insertionSessionActive = true
            try Task.checkCancellation()
            guard sessionGeneration == generation, phase == .requestingAuthorization else {
                settle(generation: generation)
                return
            }
            phase = .preparing
            let transcriber = makeTranscriber()
            activeTranscriber = transcriber
            let events = try await transcriber.transcribe(locale: localeProvider())
            try Task.checkCancellation()
            guard sessionGeneration == generation else { return }
            if phase == .stopping {
                // Stop raced engine startup; finish again so the engine the
                // first finish could not see yet is torn down and the
                // stream ends.
                if let finishTask {
                    await finishTask.value
                } else {
                    await transcriber.finishTranscribing()
                }
                settle(generation: generation)
                return
            }
            guard phase == .preparing else { return }
            phase = .listening
            for try await event in events {
                guard sessionGeneration == generation, isActive else { break }
                await handle(event, generation: generation)
            }
            guard sessionGeneration == generation, isActive else { return }
            if let delta = transcript.commitTrailingVolatileText(),
               !(await inserter.insertFinalizedText(delta)) {
                fail(.insertionTargetUnavailable, generation: generation)
                return
            }
            settle(generation: generation)
        } catch is CancellationError {
            guard sessionGeneration == generation else { return }
            // A cancelled startup may have raced far enough to create an
            // engine. Tear it down before settling so stopping never leaves
            // capture or model resources alive.
            if let finishTask {
                await finishTask.value
            } else {
                await activeTranscriber?.finishTranscribing()
            }
            settle(generation: generation)
        } catch {
            let failure = (error as? DictationFailure)
                ?? .transcriptionFailed(error.localizedDescription)
            fail(failure, generation: generation)
        }
    }

    private func authorizeMicrophone() async -> Bool {
        switch await authorizer.microphoneAuthorization() {
        case .authorized, .notRequired:
            return true
        case .denied:
            return false
        case .undetermined:
            return await authorizer.requestMicrophoneAuthorization()
        }
    }

    private func authorizeSpeechRecognition() async -> Bool {
        switch await authorizer.speechRecognitionAuthorization() {
        case .authorized, .notRequired:
            return true
        case .denied:
            return false
        case .undetermined:
            return await authorizer.requestSpeechRecognitionAuthorization()
        }
    }

    private func handle(_ event: DictationTranscriptionEvent, generation: Int) async {
        guard let delta = transcript.apply(event) else { return }
        guard await inserter.insertFinalizedText(delta) else {
            fail(.insertionTargetUnavailable, generation: generation)
            return
        }
    }

    private func settle(generation: Int) {
        guard sessionGeneration == generation, isActive else { return }
        cancelStopRecovery()
        endInsertionSessionIfActive()
        activeTranscriber = nil
        sessionTask = nil
        phase = .idle
    }

    private func fail(_ failure: DictationFailure, generation: Int) {
        // The isActive guard makes failure terminal for the session: a
        // late stream end can neither clobber .failed back to .idle nor
        // re-fire the failure handler.
        guard sessionGeneration == generation, isActive else { return }
        let transcriber = activeTranscriber
        requestFinish(transcriber: transcriber, generation: generation)
        sessionTask?.cancel()
        cancelStopRecovery()
        endInsertionSessionIfActive()
        activeTranscriber = nil
        sessionTask = nil
        phase = .failed(failure)
        failureHandler?(failure)
    }

    private func requestFinish(for generation: Int) {
        guard let transcriber = activeTranscriber else { return }
        requestFinish(transcriber: transcriber, generation: generation)
    }

    private func requestFinish(
        transcriber: (any SpeechTranscribing)?,
        generation: Int
    ) {
        guard let transcriber else { return }
        // One finish operation owns the engine shutdown for this generation.
        // Reusing it avoids racing two finalization calls when an insertion
        // failure arrives while a user-requested stop is already flushing.
        guard finishTask == nil else { return }
        finishTask = Task { [weak self] in
            await transcriber.finishTranscribing()
            guard let self, self.sessionGeneration == generation else { return }
            self.finishTask = nil
        }
    }

    /// Starts the one-shot deadline that recovers a permanently stuck stop.
    private func armStopRecovery(for generation: Int) {
        stopRecoveryTask?.cancel()
        let clock = self.clock
        stopRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: Self.stopRecoveryTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.sessionGeneration == generation,
                  self.phase == .stopping else {
                return
            }
            self.fail(
                .transcriptionFailed("dictation stop timed out"),
                generation: generation
            )
        }
    }

    private func cancelStopRecovery() {
        stopRecoveryTask?.cancel()
        stopRecoveryTask = nil
    }

    private func endInsertionSessionIfActive() {
        guard insertionSessionActive else { return }
        insertionSessionActive = false
        inserter.endSession()
    }
}
