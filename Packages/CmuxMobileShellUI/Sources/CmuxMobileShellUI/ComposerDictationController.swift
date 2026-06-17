#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Speech

/// On-device voice dictation for the composer text field.
///
/// Owns the dictation STATE MACHINE (see ``ComposerDictationState``) and the
/// composer text merge, and delegates the actual audio + recognition pipeline to
/// ``DictationAudioCapture``, which runs `AVAudioSession` / `AVAudioEngine` /
/// `SFSpeechRecognizer` entirely off the main actor on its own serial queue. That
/// split is deliberate: `AVAudioSession.setActive` and `AVAudioEngine.start` block
/// the calling thread for ~100-300ms, so running them on this `@MainActor` type was
/// the mic-button press lag. The non-Sendable AVFoundation/Speech objects live in
/// the capture; the controller only exchanges `Sendable` value snapshots with it.
///
/// Text behavior: ``start(existingText:onText:)`` captures the composer's current
/// text as the base and, for every partial result, calls `onText` with
/// base + transcript (see ``ComposerDictationTextMerger``) so dictation appends to
/// whatever the user already typed and never clobbers it.
@MainActor
@Observable
final class ComposerDictationController {
    /// The current point in the dictation state machine. Drives the mic button's
    /// enabled/listening presentation.
    private(set) var state: ComposerDictationState = .idle

    /// Pure merger that combines the captured base text with speech partials.
    private let textMerger: ComposerDictationTextMerger

    /// The off-main audio + recognition pipeline. All engine/session work runs on
    /// its private queue, so the main thread never blocks on audio activation.
    private let capture: DictationAudioCapture

    /// The composer text captured when dictation started, used as the merge base
    /// so partials append rather than overwrite.
    private var baseText: String = ""

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
        self.capture = DictationAudioCapture()
        // No recognizer for this locale is terminal: the mic is disabled.
        if !capture.hasRecognizer {
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
        guard capture.hasRecognizer else {
            state = .unavailable
            return
        }
        baseText = existingText
        self.onText = onText

        // iOS 26 trap avoidance (the mic-tap crash): when speech + mic authorization
        // is ALREADY resolved (the common case after the first grant), decide
        // synchronously and go straight to recognition. The async
        // `SFSpeechRecognizer.requestAuthorization` / `requestRecordPermission`
        // completions are dispatched by TCC on an XPC reply thread; reading the
        // status synchronously never invokes them, so a repeat tap cannot hit that
        // path. Only a genuinely undetermined permission falls through to the async
        // request below, which keeps the permission prompt gated to the first tap.
        switch Self.resolvedAuthorization() {
        case .granted:
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
        // `@Sendable` completion. Hop to the main actor ONCE here before touching
        // any actor-isolated state.
        requestAuthorization { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                // A second tap may have cancelled while authorization resolved; if
                // so this start is stale. Do nothing, so a cancel during the
                // permission flow neither starts the engine nor overwrites the
                // user's idle state with `unavailable`.
                guard self.state == .requestingPermission else { return }
                guard granted else {
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
    /// loss: the user intends to keep what they said. Flushes buffered audio and
    /// stops the engine (off-main, via the capture) but keeps the recognition task
    /// alive to deliver its final result, which refines the committed text before
    /// cleanup. A watchdog force-finishes if no final result arrives.
    func stop() {
        guard state == .listening else {
            // From any non-listening state a graceful stop is a no-op except for
            // clearing a stuck-open mic: hard-cancel so callers always settle.
            cancel()
            return
        }
        state = .stopping
        capture.finishGraceful()
        finalizeTimeout?.cancel()
        finalizeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finalizeTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishGraceful()
        }
    }

    /// Hard-cancel dictation and tear everything down immediately. Used when the
    /// user navigates away (`onDisappear`, terminal switch) where losing the
    /// unrecognized tail is acceptable. Idempotent and safe to call from any state.
    func cancel() {
        if state == .listening || state == .stopping { state = .stopping }
        teardown()
        if state != .unavailable {
            state = .idle
        }
    }

    // MARK: - Recognition lifecycle

    /// Start the off-main audio + recognition pipeline. State flips to `.listening`
    /// immediately so the mic button animates without waiting on audio activation;
    /// the capture reports readiness (or failure) and streams results back through
    /// `@Sendable` callbacks that hop to the main actor.
    private func beginRecognition() {
        state = .listening
        capture.start(
            onResult: { [weak self] transcript, isFinal, failed in
                Task { @MainActor in
                    self?.handleResult(transcript: transcript, isFinal: isFinal, failed: failed)
                }
            },
            onReady: { [weak self] ok in
                Task { @MainActor in
                    self?.handleReady(ok)
                }
            }
        )
    }

    /// React to the capture finishing (or failing) audio activation. Only a still
    /// `.listening` session cares: if the user already stopped/cancelled, the
    /// capture teardown is already queued and there is nothing to do.
    private func handleReady(_ ok: Bool) {
        guard state == .listening else { return }
        if !ok {
            failStart()
        }
    }

    /// Apply a recognition result (on the main actor) and settle the session on a
    /// final result or error.
    private func handleResult(transcript: String?, isFinal: Bool, failed: Bool) {
        // Only apply a NON-EMPTY transcript. On stop, the recognizer can deliver a
        // final result with an empty transcript; merging that (`merged(base, "")`
        // -> `base`) would wipe the words the partials already committed. The latest
        // non-empty partial is already in the field, so ignore an empty one.
        if let transcript, !transcript.isEmpty {
            onText?(textMerger.merged(base: baseText, transcript: transcript))
        }
        // A final result or an error settles the session. If a graceful stop is in
        // flight, this is the awaited final result: apply it (above) and finish
        // cleanup. While still listening, the stream ended on its own; cancel.
        if isFinal || failed {
            if state == .stopping {
                finishGraceful()
            } else {
                cancel()
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

    /// Finish a graceful stop after the recognition task delivered its final result
    /// (or the watchdog fired): drop the pipeline and callback, and return to idle.
    /// A no-op once the controller has left `.stopping` (final result and watchdog
    /// can race; whichever lands first wins).
    private func finishGraceful() {
        guard state == .stopping else { return }
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        capture.cancel()
        onText = nil
        baseText = ""
        state = .idle
    }

    /// Cancel the recognition task and clear the callback. Safe to call repeatedly.
    private func teardown() {
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        capture.cancel()
        onText = nil
        baseText = ""
    }

    // MARK: - Authorization

    /// Whether both authorizations are already resolved, and if so the verdict.
    /// `undetermined` means at least one permission has never been requested, so a
    /// first-time async prompt is still required.
    private enum AuthResolution { case granted, denied, undetermined }

    /// Read the CURRENT speech + microphone authorization synchronously, without
    /// invoking any async request completion. `nonisolated` and side-effect-free:
    /// these status getters are plain synchronous reads, so they are safe to call
    /// from the main actor and never touch the crashing TCC callback path, and never
    /// prompt (the prompt stays gated to the first-tap async request).
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
    /// BOTH were granted. `nonisolated` with a `@Sendable` completion ON PURPOSE:
    /// `SFSpeechRecognizer` / `AVFoundation` invoke their completion handlers on
    /// their own (non-main) queues, and a main-actor-isolated closure invoked there
    /// traps in `swift_task_isCurrentExecutor`. Keeping the chain nonisolated means
    /// no `@MainActor` closure is ever invoked off-main; the caller hops once.
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
    /// fallback. `nonisolated` + `@Sendable` for the same off-main-isolation reason
    /// as ``requestAuthorization(_:)``; reports on the system's queue.
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
}
#endif
