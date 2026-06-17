#if os(iOS)
import AVFoundation
import Foundation
import Observation
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
/// to avoid a retain cycle through the recognition task.
@MainActor
@Observable
final class ComposerDictationController {
    /// The current point in the dictation state machine. Drives the mic button's
    /// enabled/listening presentation.
    private(set) var state: ComposerDictationState = .idle

    /// The recognizer for the user's locale. `nil` when the locale is
    /// unsupported, which is surfaced as ``ComposerDictationState/unavailable``.
    private let recognizer: SFSpeechRecognizer?

    /// Pure merger that combines the captured base text with speech partials.
    private let textMerger: ComposerDictationTextMerger

    /// The audio engine capturing microphone buffers. Built lazily on first
    /// start and reused; its input-node tap is installed on start and removed on
    /// every teardown.
    private let audioEngine = AVAudioEngine()

    /// The in-flight recognition request, fed audio buffers from the engine tap.
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// The in-flight recognition task. Cancelled and cleared on every teardown.
    private var task: SFSpeechRecognitionTask?

    /// The composer text captured when dictation started, used as the merge base
    /// so partials append rather than overwrite.
    private var baseText: String = ""

    /// Whether THIS controller activated the shared `AVAudioSession` (`setActive`
    /// in `beginRecognition()`). Gates teardown so a send/blur/cancel with no
    /// dictation in flight never pokes the audio system. See ``stopEngineAndSession()``.
    private var didActivateSession = false

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

    init(textMerger: ComposerDictationTextMerger = ComposerDictationTextMerger()) {
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
    var isAvailable: Bool { state != .unavailable }

    /// Whether dictation currently owns the composer text, so the field must be
    /// locked (non-editable) until dictation settles to idle. True while
    /// `.listening` (partials streaming in) and `.stopping` (final result
    /// pending); see ``ComposerDictationState/locksComposerField``. The view binds
    /// the field's `.disabled(...)` to this so a user edit made mid-dictation can
    /// never be clobbered by a later partial/final callback. The mic toggle and
    /// send remain usable while locked.
    var locksComposerField: Bool { state.locksComposerField }

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
    func toggle(existingText: String, onText: @escaping (String) -> Void) {
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

    /// Abort a start whose authorization has not resolved yet. Drops the captured
    /// callback and returns to idle without touching the engine (none is running),
    /// so the in-flight permission callback sees a non-`requestingPermission` state
    /// and refuses to start. Safe to call only from `requestingPermission`.
    private func cancelPendingStart() {
        onText = nil
        baseText = ""
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
    func stop() {
        // Only a live listening session can be finalized. From any other state a
        // graceful stop is a no-op except for clearing a stuck-open mic: fall back
        // to a hard cancel so callers (focus loss, send) always settle the state.
        guard state == .listening else {
            cancel()
            return
        }
        state = .stopping
        // Flush buffered audio so a late FINAL result can include the tail, then
        // stop capturing. The task and `onText` stay alive to receive that result.
        request?.endAudio()
        stopEngineAndSession()
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
    func cancel() {
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

    /// Configure the audio session, install the engine tap, and start the
    /// recognition task. On any setup failure this tears down and lands in
    /// `unavailable` so the mic does not appear hot after a failed start.
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

        do {
            let session = AVAudioSession.sharedInstance()
            // Record-only category for speech-to-text. `.duckOthers` is NOT valid
            // for `.record`, and `.notifyOthersOnDeactivation` is only valid on
            // deactivation, so both are omitted here; passing them throws on OSes
            // that enforce the documented restrictions.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            // Set before later setup so a failure still deactivates on failStart.
            didActivateSession = true
        } catch {
            failStart()
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Validate the input format; an invalid one makes `installTap` raise an
        // uncatchable Obj-C exception.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            failStart()
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(request: request))

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            failStart()
            return
        }

        task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionResultHandler())

        state = .listening
    }

    /// Build the audio-tap block. `nonisolated` so the returned closure is NOT
    /// main-actor-isolated: `installTap` invokes it on the realtime audio render
    /// thread, where a main-actor closure traps in `swift_task_isCurrentExecutor`.
    /// `append` is thread-safe on the request; no main-actor state is touched.
    private nonisolated static func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [weak request] buffer, _ in
            request?.append(buffer)
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

    /// Stop the audio engine, remove the input tap, and deactivate the audio
    /// session. Shared by the graceful stop (which keeps the recognition task and
    /// callback alive) and the hard `teardown()`. Safe to call repeatedly.
    private func stopEngineAndSession() {
        // No-op unless we activated the session. Otherwise this would touch the
        // audio system on every send/blur/cancel: accessing `audioEngine.inputNode`
        // powers up the mic route and `setActive(false, .notifyOthersOnDeactivation)`
        // interrupts other apps' playback (music pausing/resuming on every submit).
        guard didActivateSession else { return }
        didActivateSession = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        // The tap must be removed whether or not the engine was running, so a
        // failed start that installed the tap before `start()` threw does not
        // leak it onto the input node.
        audioEngine.inputNode.removeTap(onBus: 0)
        // Deactivate the audio session so other audio (and the system) reclaim it.
        // Failure here is non-fatal: the engine is already stopped.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Cancel the recognition task, end and drop the request, remove the audio
    /// tap, stop the engine, deactivate the audio session, and clear the
    /// callback. Safe to call repeatedly; every reference is nil-checked.
    private func teardown() {
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        stopEngineAndSession()
        onText = nil
        baseText = ""
    }
}
#endif
