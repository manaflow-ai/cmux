#if os(iOS)
import AVFoundation
import Foundation
public import Observation
import Speech

/// On-device voice dictation for the composer text field.
///
/// Wraps `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` driven by
/// an `AVAudioEngine` tap, exposing a thin start/stop surface and a published
/// state machine (see ``ComposerDictationState``) so the SwiftUI view stays
/// declarative. On-device recognition is preferred when supported
/// (`requiresOnDeviceRecognition = true`) for privacy and offline use, falling
/// back to server recognition only when the device cannot recognize locally.
///
/// Text behavior: ``start(existingText:onText:)`` captures the composer's current
/// text as the base and, for every partial result, calls `onText` with
/// base + transcript (see ``ComposerDictationTextMerger``) so dictation appends to
/// whatever the user already typed and never clobbers it.
///
/// Concurrency: the type is `@MainActor`, so all published state and the `onText`
/// callback mutate the store on the main actor. Speech / AVFoundation deliver
/// their recognition callbacks on an arbitrary queue, so the result handler hops
/// back to the main actor before touching any state, and captures `self` weakly
/// to avoid a retain cycle through the recognition task. The blocking audio
/// session/engine activation and teardown are delegated to
/// ``ComposerDictationAudioEngine`` (its own serial queue), so this main-actor
/// controller never blocks on the audio hardware (issue #6284); a monotonic
/// ``startToken`` lets a late engine-ready callback detect a superseded start.
@MainActor
@Observable
public final class ComposerDictationController {
    /// The current point in the dictation state machine. Drives the mic button's
    /// enabled/listening presentation.
    public private(set) var state: ComposerDictationState = .idle

    /// The recognizer for the user's locale. `nil` when the locale is
    /// unsupported, which is surfaced as ``ComposerDictationState/unavailable``.
    private let recognizer: SFSpeechRecognizer?

    /// Pure merger that combines the captured base text with speech partials.
    private let textMerger: ComposerDictationTextMerger

    /// Owns the `AVAudioEngine` + shared `AVAudioSession` lifecycle on its own
    /// serial queue so the synchronous `setActive`/`engine.start`/`engine.stop`
    /// hardware calls (each ~100-300ms) never block this `@MainActor` controller
    /// and freeze the mic button animation (issue #6284).
    private let audioEngine = ComposerDictationAudioEngine()

    /// The in-flight recognition request, fed audio buffers from the engine tap.
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// The in-flight recognition task. Cancelled and cleared on every teardown.
    private var task: SFSpeechRecognitionTask?

    /// The composer text captured when dictation started, used as the merge base
    /// so partials append rather than overwrite.
    private var baseText: String = ""

    /// Monotonic token identifying the current start attempt. The engine activates
    /// off-main (see ``audioEngine``), so its "ready" callback lands ~100-300ms
    /// after the tap; in that window a second tap, send, or navigation can abandon
    /// the start. Every new start AND every teardown bumps this token, so a late
    /// engine-ready callback detects it was superseded
    /// (``ComposerDictationState/startDisposition(callbackToken:currentToken:)``)
    /// and discards its result. (Replaces the old `didActivateSession` gate, now
    /// internal to ``ComposerDictationAudioEngine``.)
    private var startToken = 0

    /// The callback that writes merged text back into the composer. Held while
    /// listening AND through a graceful stop (so the final result can refine the
    /// committed text); cleared on cleanup so a late callback cannot mutate the
    /// store after the user left.
    private var onText: ((String) -> Void)?

    /// Pending watchdog that force-finishes a graceful stop if the recognition
    /// task never delivers a final result. Cancelled when the final result (or an
    /// error) lands first, or when a hard cancel supersedes the graceful stop.
    private var finalizeTimeout: Task<Void, Never>?

    /// How long a graceful stop waits for the recognition task's final result
    /// before force-finishing cleanup, so the controller cannot hang in
    /// `.stopping` if no final result ever arrives.
    private static let finalizeTimeoutSeconds: Double = 2.5
    /// Creates a dictation controller for the current speech-recognition locale.
    public init(textMerger: ComposerDictationTextMerger = ComposerDictationTextMerger()) {
        self.textMerger = textMerger
        self.recognizer = SFSpeechRecognizer()
        // A nil recognizer (unsupported locale) is terminal: the mic is disabled.
        if recognizer == nil {
            state = .unavailable
        }
    }

    /// Whether the mic button should be shown enabled. False only when the
    /// recognizer is permanently unavailable (unsupported locale, denied, or
    /// restricted); a transient busy state still leaves the button enabled so the
    /// user can toggle it off.
    public var isAvailable: Bool { state != .unavailable }

    /// Whether dictation currently owns the composer text, so the field must be
    /// locked (non-editable) until dictation settles to idle. True from
    /// `.requestingPermission` (the engine spins up off-main; locking here closes
    /// the async edit-loss window) through `.listening` and `.stopping`; see
    /// ``ComposerDictationState/locksComposerField``. The view binds the field's
    /// `.disabled(...)` to this so a mid-dictation edit can never be clobbered by a
    /// later partial/final callback. The mic toggle and send remain usable.
    public var locksComposerField: Bool { state.locksComposerField }

    /// Toggle dictation: start if idle, stop if already listening, or cancel a
    /// pending start if authorization is still resolving.
    ///
    /// A second tap while in ``ComposerDictationState/requestingPermission`` aborts
    /// the pending start: the state returns to idle so the permission-completion
    /// callback (which guards on `requestingPermission`) does not start the engine.
    /// A later tap can then start dictation normally.
    ///
    /// - Parameters:
    ///   - existingText: The composer's current text, captured as the merge base.
    ///   - onText: Receives merged text (base + transcript) on the main actor for
    ///     every partial and the final result.
    public func toggle(existingText: String, onText: @escaping (String) -> Void) {
        if state.isListening {
            // The visible Stop button: finalize gracefully so the last spoken
            // words are not dropped.
            stop()
        } else if state.canCancelPendingStart {
            cancelPendingStart()
        } else {
            start(existingText: existingText, onText: onText)
        }
    }

    /// Abort a start that is still settling and return to idle. Safe to call only
    /// from `requestingPermission`, which now covers both authorization resolving
    /// (no engine yet) and the engine spinning up off-main. ``teardown()`` handles
    /// both: it bumps the start token (discarding a late engine-ready callback) and
    /// enqueues an engine stop (a no-op if nothing activated, a real teardown
    /// otherwise). The permission callback guards on `requestingPermission`, so
    /// once this lands in idle it refuses to start.
    private func cancelPendingStart() {
        teardown()
        state = .idle
    }

    /// Begin dictation: resolve authorization, then start the engine and stream
    /// partial transcriptions through `onText`. A no-op unless the state machine
    /// allows a start (idle and available).
    func start(existingText: String, onText: @escaping (String) -> Void) {
        guard state.canStart else { return }
        guard recognizer != nil else {
            state = .unavailable
            return
        }
        baseText = existingText
        self.onText = onText

        // iOS 26 trap avoidance (the real mic-tap crash): when speech + mic
        // authorization is ALREADY resolved (the common case after the first
        // grant), decide synchronously and go straight to recognition. The async
        // `SFSpeechRecognizer.requestAuthorization` / `requestRecordPermission`
        // completions are dispatched by TCC on an XPC reply thread; a Swift
        // closure the compiler treats as main-actor-isolated traps there in
        // `swift_task_isCurrentExecutor` -> `dispatch_assert_queue_fail`. Reading
        // the status synchronously never invokes that completion, so a repeat tap
        // (Lawrence's repro) cannot hit the crashing callback. Only a genuinely
        // undetermined permission falls through to the async request below.
        switch Self.resolvedAuthorization() {
        case .granted:
            state = .requestingPermission
            beginRecognition()
            return
        case .denied:
            self.onText = nil
            state = .unavailable
            return
        case .undetermined:
            // First-ever request: fall through to the async prompt below.
            break
        }

        state = .requestingPermission
        // The Speech/AVFoundation authorization callbacks fire on their own
        // (non-main) queues, so `requestAuthorization` is nonisolated with a
        // `@Sendable` completion. Hop to the main actor ONCE, here, via
        // `Task { @MainActor in }` (an async enqueue, not a synchronous executor
        // assertion) before touching any actor-isolated state.
        requestAuthorization { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                // A second tap may have cancelled (or otherwise moved on) while
                // authorization resolved; if so this start is stale. Do nothing, so
                // a cancel during the permission flow neither starts the engine nor
                // overwrites the user's idle state with `unavailable`.
                guard self.state == .requestingPermission else { return }
                guard granted else {
                    // Denied or restricted: a terminal rest state that disables the
                    // mic. The captured callback is dropped.
                    self.onText = nil
                    self.state = .unavailable
                    return
                }
                self.beginRecognition()
            }
        }
    }

    /// Gracefully stop dictation, finalizing the transcript before cleanup. Used
    /// for the visible Stop button, the stop right before send, and field focus
    /// loss: the user intends to keep what they said.
    ///
    /// Flushes buffered audio (`endAudio()`) and stops the engine, but does NOT
    /// cancel the recognition task or drop `onText`. The state moves to
    /// `.stopping` and the in-flight task is left to deliver its final result,
    /// which `onText` applies to the composer (refining the last partial) before
    /// cleanup runs in `finishGraceful()`. A watchdog force-finishes if no final
    /// result arrives, so the controller cannot hang in `.stopping`.
    ///
    /// The latest partial is already committed to the composer (every partial
    /// wrote through `onText` while listening), so the user's words are preserved
    /// even if the final result is only a refinement or never arrives.
    public func stop() {
        // Only a live listening session can be finalized. From any other state a
        // graceful stop is a no-op except for clearing a stuck-open mic: fall back
        // to a hard cancel so callers (focus loss, send) always settle the state.
        guard state == .listening else {
            cancel()
            return
        }
        state = .stopping
        // Flush buffered audio so a late FINAL result can include the tail, then
        // stop capturing OFF the main actor: `engine.stop()` + `setActive(false)`
        // block ~100-300ms and froze the button animation when run inline (issue
        // #6284). The task and `onText` stay alive for the final result.
        request?.endAudio()
        audioEngine.stop()
        // Watchdog: if no final result (or error) lands, force cleanup so the
        // controller returns to idle instead of hanging in `.stopping`.
        finalizeTimeout?.cancel()
        finalizeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finalizeTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishGraceful()
        }
    }

    /// Hard-cancel dictation and tear everything down immediately: cancel the
    /// task, end the request, remove the audio tap, stop the engine, deactivate
    /// the session, and drop the callback. Used when the user navigates away
    /// (`onDisappear`, terminal switch) where losing the unrecognized tail is
    /// acceptable. Idempotent and safe to call from any state.
    public func cancel() {
        if state == .listening || state == .stopping { state = .stopping }
        teardown()
        // Preserve a terminal `unavailable`; otherwise return to idle. A cancel
        // from an already-idle state is a harmless no-op (teardown is nil-checks).
        if state != .unavailable {
            state = .idle
        }
    }

    // MARK: - Authorization

    /// Whether both authorizations are already resolved, and if so the verdict.
    /// `undetermined` means at least one permission has never been requested, so a
    /// first-time async prompt is still required.
    private enum AuthResolution { case granted, denied, undetermined }

    /// Read the CURRENT speech + microphone authorization synchronously, without
    /// invoking any async request completion. `nonisolated` and side-effect-free:
    /// these status getters are plain synchronous reads, so they are safe to call
    /// from the main actor and never touch the crashing TCC callback path.
    private nonisolated static func resolvedAuthorization() -> AuthResolution {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let micGranted: Bool
        let micDetermined: Bool
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: micGranted = true; micDetermined = true
            case .denied: micGranted = false; micDetermined = true
            case .undetermined: micGranted = false; micDetermined = false
            @unknown default: micGranted = false; micDetermined = false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: micGranted = true; micDetermined = true
            case .denied: micGranted = false; micDetermined = true
            case .undetermined: micGranted = false; micDetermined = false
            @unknown default: micGranted = false; micDetermined = false
            }
        }
        guard speech != .notDetermined, micDetermined else { return .undetermined }
        return (speech == .authorized && micGranted) ? .granted : .denied
    }

    /// Resolve speech-recognition then microphone authorization and report whether
    /// BOTH were granted.
    ///
    /// `nonisolated` with a `@Sendable` completion ON PURPOSE: `SFSpeechRecognizer`
    /// / `AVFoundation` invoke their completion handlers on their own (non-main)
    /// queues. If those closures were main-actor-isolated (the default for a
    /// closure written inside this `@MainActor` type), Swift 6 on iOS 26 asserts
    /// executor isolation when the system calls them off-main and traps
    /// (`EXC_BREAKPOINT` in `swift_task_isCurrentExecutor` ->
    /// `dispatch_assert_queue_fail`), which is the mic-tap crash. Keeping the
    /// whole authorization chain nonisolated means no `@MainActor` closure is ever
    /// invoked off-main; the caller hops to the main actor once.
    private nonisolated func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                completion(false)
                return
            }
            Self.requestMicrophonePermission(completion)
        }
    }

    /// Request microphone permission, bridging the iOS 17+ API to its pre-17
    /// fallback. `nonisolated` + `@Sendable` for the same off-main-isolation
    /// reason as ``requestAuthorization(_:)``; reports on the system's queue.
    private nonisolated static func requestMicrophonePermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        }
    }

    // MARK: - Recognition

    /// Begin dictation by handing the audio session + engine activation to the
    /// off-main ``ComposerDictationAudioEngine``, then create the recognition task
    /// when it reports ready — the blocking `setActive`/`engine.start` run on the
    /// owner's serial queue, NOT here, so the mic button never hitches (issue
    /// #6284). The state stays `.requestingPermission` until ``handleEngineReady``.
    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            failStart()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device recognition for privacy and offline use; fall back to
        // server recognition only when the device cannot recognize locally.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // Stamp this start attempt: the off-main activation calls back ~100-300ms
        // later, by when a second tap, send, or navigation may have superseded it.
        // Each supersede bumps the token, so a stale callback is discarded.
        startToken &+= 1
        let token = startToken

        // Hand the blocking audio-hardware work to the owner's serial queue; the
        // state stays `.requestingPermission` until it reports ready, then
        // `handleEngineReady` creates the recognition task on the main actor (so
        // the non-Sendable request/recognizer never leave it).
        audioEngine.start(tapBlock: makeTapBlock(request: request)) { [weak self] started in
            // Hop to the main actor before touching actor-isolated state.
            Task { @MainActor in self?.handleEngineReady(started, token: token) }
        }
    }

    /// Apply the off-main engine owner's start result on the main actor. Discards
    /// the result when a newer start / cancel / teardown superseded this attempt
    /// (that path already enqueued the engine teardown, serialized before any later
    /// start, so a second stop here could instead tear down that later start);
    /// otherwise creates the recognition task and moves to `.listening` (or
    /// `.unavailable` if the engine failed to start).
    private func handleEngineReady(_ started: Bool, token: Int) {
        guard state.startDisposition(
            callbackToken: token, currentToken: startToken
        ) == .apply else { return }
        guard started, let recognizer, let request else {
            failStart()
            return
        }
        task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionResultHandler())
        state = .listening
    }

    /// Build the audio-tap block handed to the off-main ``audioEngine`` owner.
    /// `@Sendable` + `nonisolated` so it crosses into the owner's queue and runs
    /// off-main (a main-actor closure would trap in `swift_task_isCurrentExecutor`
    /// on the realtime render thread). The request is captured `nonisolated(unsafe)`
    /// (justified inline) because it is not `Sendable`. `nonisolated` (uses no `self`).
    private nonisolated func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        // `nonisolated(unsafe)`-safe: `append(_:)` is thread-safe, weak, never outlives the request.
        nonisolated(unsafe) weak var weakRequest: SFSpeechAudioBufferRecognitionRequest? = request
        return { buffer, _ in
            weakRequest?.append(buffer)
        }
    }

    /// Build the recognition result handler. `nonisolated` so the returned closure
    /// is NOT main-actor-isolated: `SFSpeechRecognitionTask` delivers results on an
    /// arbitrary queue. The closure extracts only `Sendable` value snapshots and
    /// hops to the main actor via `Task { @MainActor in }` before touching any
    /// actor-isolated state; `self` is weak so the task does not retain the
    /// controller.
    private nonisolated func makeRecognitionResultHandler()
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        // `@Sendable` so the closure is its own isolation region (not main-actor):
        // Speech invokes it off-main, where a main-actor closure traps. It captures
        // only `[weak self]` (a Sendable, main-actor class) and reads Sendable
        // snapshots from the non-Sendable result/error PARAMETERS, then hops to the
        // main actor. This mirrors the authorization completion pattern above.
        return { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                // Only apply a NON-EMPTY transcript. On stop, the recognizer can
                // deliver a final result with an empty transcript; merging that
                // (`merged(base, "")` -> `base`) would wipe the words the partials
                // already committed. The latest non-empty partial is already in the
                // field, so an empty final/partial must be ignored, not applied.
                if let transcript, !transcript.isEmpty {
                    self.onText?(self.textMerger.merged(
                        base: self.baseText,
                        transcript: transcript
                    ))
                }
                // A final result or an error (end-of-stream, recognition failure)
                // settles the session so the mic does not stay hot. If a graceful
                // stop is already in flight (`.stopping`), this is the awaited
                // final result: apply it (done above) and finish cleanup. While
                // still listening, the stream ended on its own; cancel to idle.
                if isFinal || failed {
                    if self.state == .stopping {
                        self.finishGraceful()
                    } else {
                        self.cancel()
                    }
                }
            }
        }
    }

    /// Tear down after a setup failure and disable the mic. Distinct from a clean
    /// stop because a failed start indicates the recognizer cannot be used right
    /// now (no input route, session error, recognizer offline).
    private func failStart() {
        teardown()
        state = .unavailable
    }

    /// Finish a graceful stop after the recognition task delivered its final
    /// result (or the watchdog fired): drop the task/request and callback, and
    /// return to idle. The engine and session are already stopped by `stop()`.
    /// A no-op once the controller has left `.stopping` (final result and
    /// watchdog can race; whichever lands first wins, the other is ignored).
    private func finishGraceful() {
        guard state == .stopping else { return }
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        // The task already finalized; cancelling a finished task is a no-op, and
        // it guarantees no late callback survives if the watchdog won the race.
        task?.cancel()
        task = nil
        request = nil
        onText = nil
        baseText = ""
        state = .idle
    }

    /// Cancel the recognition task, end and drop the request, stop the engine and
    /// deactivate the session (off-main, via ``audioEngine``), and clear the
    /// callback. Safe to call repeatedly; every reference is nil-checked.
    private func teardown() {
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        // Bump the start token so an in-flight engine-start callback sees it was
        // superseded and discards its result. The `audioEngine.stop()` below is
        // serialized after that start's activation and before any later start, so
        // the engine is reliably torn down and never double-started.
        startToken &+= 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        // Off the main actor; a no-op if nothing was activated (so a send/blur/
        // cancel with no dictation in flight never pokes the audio system).
        audioEngine.stop()
        onText = nil
        baseText = ""
    }
}
#endif
