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
    private var activeTranscriber: (any SpeechTranscribing)?
    private var sessionTask: Task<Void, Never>?
    private var sessionGeneration = 0

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - authorizer: Permission checker/requester.
    ///   - inserter: Router that pins a focus target per session and types
    ///     finalized text into it.
    ///   - makeTranscriber: Factory producing a fresh engine per session.
    ///   - localeProvider: Supplies the dictation language at session start
    ///     (read from settings each time, so changes apply immediately).
    public init(
        authorizer: any DictationAuthorizing,
        inserter: any DictationTextInserting,
        makeTranscriber: @escaping @MainActor () -> any SpeechTranscribing,
        localeProvider: @escaping @MainActor () -> Locale
    ) {
        self.authorizer = authorizer
        self.inserter = inserter
        self.makeTranscriber = makeTranscriber
        self.localeProvider = localeProvider
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
        guard isActive else { return }
        if phase == .requestingAuthorization {
            // No transcriber exists yet; runSession observes the phase
            // change after the authorization awaits and unwinds.
            phase = .stopping
            return
        }
        phase = .stopping
        let transcriber = activeTranscriber
        Task {
            await transcriber?.finishTranscribing()
        }
    }

    private func runSession(generation: Int) async {
        guard await authorizeMicrophone() else {
            fail(.microphoneAccessDenied, generation: generation)
            return
        }
        guard await authorizeSpeechRecognition() else {
            fail(.speechRecognitionAccessDenied, generation: generation)
            return
        }
        guard sessionGeneration == generation, phase == .requestingAuthorization else {
            // Stopped (or superseded) while a permission prompt was up.
            settle(generation: generation)
            return
        }
        guard inserter.beginSession() else {
            fail(.insertionTargetUnavailable, generation: generation)
            return
        }
        phase = .preparing
        let transcriber = makeTranscriber()
        activeTranscriber = transcriber
        do {
            let events = try await transcriber.transcribe(locale: localeProvider())
            if sessionGeneration == generation, phase == .stopping {
                // Stop raced engine startup; finish again so the engine the
                // first finish could not see yet is torn down and the
                // stream ends.
                await transcriber.finishTranscribing()
            } else if sessionGeneration == generation, phase == .preparing {
                phase = .listening
            }
            for try await event in events {
                guard sessionGeneration == generation, isActive else { break }
                handle(event, generation: generation)
            }
            guard sessionGeneration == generation, isActive else { return }
            if let delta = transcript.commitTrailingVolatileText() {
                _ = inserter.insertFinalizedText(delta)
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

    private func handle(_ event: DictationTranscriptionEvent, generation: Int) {
        guard let delta = transcript.apply(event) else { return }
        guard inserter.insertFinalizedText(delta) else {
            let transcriber = activeTranscriber
            Task { await transcriber?.finishTranscribing() }
            fail(.insertionTargetUnavailable, generation: generation)
            return
        }
    }

    private func settle(generation: Int) {
        guard sessionGeneration == generation, isActive else { return }
        inserter.endSession()
        activeTranscriber = nil
        phase = .idle
    }

    private func fail(_ failure: DictationFailure, generation: Int) {
        // The isActive guard makes failure terminal for the session: a
        // late stream end can neither clobber .failed back to .idle nor
        // re-fire the failure handler.
        guard sessionGeneration == generation, isActive else { return }
        inserter.endSession()
        activeTranscriber = nil
        phase = .failed(failure)
        failureHandler?(failure)
    }
}
