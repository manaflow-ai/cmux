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

    /// Factory consulted for every dictation start. The app composition root
    /// swaps this to Parakeet when the user selected it and its model is installed.
    ///
    /// This is a composition-root seam rather than an init dependency because the
    /// two controllers are constructed where no DI path exists today: inside the
    /// UIKit-hosted `TerminalComposerView` (built by `GhosttySurfaceRepresentable`,
    /// outside the SwiftUI environment) and inside `CmuxAgentChatUI`, which has no
    /// dependency on `CmuxVoice`. `AppCompositionRoot` installs the factory once at
    /// process start, before any composer view can exist; nothing else may mutate it.
    /// Fold this into constructor injection when composer hosting is unified.
    public static var backendFactory: @MainActor () -> any ComposerDictationRecognitionBackend = {
        AppleComposerDictationRecognitionBackend()
    }

    /// Pure merger that combines the captured base text with speech partials.
    private let textMerger: ComposerDictationTextMerger

    /// Owns the `AVAudioEngine` + shared `AVAudioSession` lifecycle on its own
    /// serial queue so the synchronous `setActive`/`engine.start`/`engine.stop`
    /// hardware calls (each ~100-300ms) never block this `@MainActor` controller
    /// and freeze the mic button animation (issue #6284).
    private let audioEngine = ComposerDictationAudioEngine()

    /// The in-flight recognition backend, fed audio buffers from the engine tap.
    private var backend: (any ComposerDictationRecognitionBackend)?

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
        // A nil recognizer (unsupported locale) is terminal: the mic is disabled.
        if !Self.backendFactory().isSupported {
            state = .unavailable
        }
    }

    /// Whether the mic button should be shown enabled. False only when the
    /// recognizer is permanently unavailable (unsupported locale, denied, or
    /// restricted); a transient busy state still leaves the button enabled so the
    /// user can toggle it off.
    /// `.unavailable` is per-backend, not permanent: a usable engine can appear
    /// later (Parakeet installed and selected on a locale Apple Speech does not
    /// support). Consult the factory on read — pure, no state mutation — so the
    /// mic button re-enables and `toggle()` can perform the actual recovery.
    public var isAvailable: Bool { state != .unavailable || Self.backendFactory().isSupported }

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
        // `.unavailable` is terminal for a given backend, not for the controller:
        // the user can install and select a different engine (e.g. Parakeet on a
        // locale Apple Speech does not support) after this controller was created.
        // Re-consult the factory so the mic recovers without recreating the view.
        if state == .unavailable, Self.backendFactory().isSupported {
            state = .idle
        }
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
        let backend = Self.backendFactory()
        guard backend.isSupported else {
            state = .unavailable
            return
        }
        self.backend = backend
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
        switch backend.resolvedAuthorization() {
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
        backend.requestAuthorization { [weak self] granted in
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
        // #6284). The backend and `onText` stay alive for the final result.
        backend?.endAudio()
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

    // MARK: - Recognition

    /// Begin dictation by handing the audio session + engine activation to the
    /// off-main ``ComposerDictationAudioEngine``, then starts the recognition
    /// backend when it reports ready. The blocking `setActive`/`engine.start` run
    /// on the owner's serial queue, NOT here, so the mic button never hitches
    /// (issue #6284). The state stays `.requestingPermission` until
    /// ``handleEngineReady``.
    private func beginRecognition() {
        guard let backend, backend.isAvailable else {
            failStart()
            return
        }

        // Stamp this start attempt: the off-main activation calls back ~100-300ms
        // later, by when a second tap, send, or navigation may have superseded it.
        // Each supersede bumps the token, so a stale callback is discarded.
        startToken &+= 1
        let token = startToken

        // Hand the blocking audio-hardware work to the owner's serial queue.
        // The backend constructs the tap while still on the main actor; the
        // returned closure is sendable and safe for the audio render thread.
        audioEngine.start(tapBlock: backend.makeTapBlock()) { [weak self] started in
            // Hop to the main actor before touching actor-isolated state.
            Task { @MainActor in self?.handleEngineReady(started, token: token) }
        }
    }

    /// Apply the off-main engine owner's start result on the main actor. Discards
    /// the result when a newer start / cancel / teardown superseded this attempt
    /// (that path already enqueued the engine teardown, serialized before any later
    /// start, so a second stop here could instead tear down that later start);
    /// otherwise starts the recognition backend and moves to `.listening` (or
    /// `.unavailable` if the engine failed to start).
    private func handleEngineReady(_ started: Bool, token: Int) {
        guard state.startDisposition(
            callbackToken: token, currentToken: startToken
        ) == .apply else { return }
        guard started, let backend else {
            failStart()
            return
        }
        backend.start { [weak self] update in
            self?.handleRecognitionUpdate(update)
        }
        state = .listening
    }

    private func handleRecognitionUpdate(_ update: ComposerDictationRecognitionUpdate) {
        switch update {
        case .transcript(let transcript, let isFinal):
            // Only apply a NON-EMPTY transcript. On stop, a backend can deliver
            // a final result with an empty transcript; merging that
            // (`merged(base, "")` -> `base`) would wipe the words the partials
            // already committed. The latest non-empty partial is already in the
            // field, so an empty final/partial must be ignored, not applied.
            if !transcript.isEmpty {
                onText?(textMerger.merged(base: baseText, transcript: transcript))
            }
            if isFinal {
                settleRecognitionStream()
            }
        case .finished, .failed:
            settleRecognitionStream()
        }
    }

    private func settleRecognitionStream() {
        if state == .stopping {
            finishGraceful()
        } else if state == .listening {
            cancel()
        }
    }

    /// Tear down after a setup failure and disable the mic. Distinct from a clean
    /// stop because a failed start indicates the recognizer cannot be used right
    /// now (no input route, session error, recognizer offline).
    private func failStart() {
        teardown()
        state = .unavailable
    }

    /// Finish a graceful stop after the recognition backend delivered its final
    /// result (or the watchdog fired): drop the backend and callback, and
    /// return to idle. The engine and session are already stopped by `stop()`.
    /// A no-op once the controller has left `.stopping` (final result and
    /// watchdog can race; whichever lands first wins, the other is ignored).
    private func finishGraceful() {
        guard state == .stopping else { return }
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        // The backend already finalized; cancelling a finished backend is a no-op,
        // and guarantees no late callback survives if the watchdog won the race.
        backend?.cancel()
        backend = nil
        onText = nil
        baseText = ""
        state = .idle
    }

    /// Cancel the recognition backend, stop the engine and
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
        backend?.cancel()
        backend = nil
        // Off the main actor; a no-op if nothing was activated (so a send/blur/
        // cancel with no dictation in flight never pokes the audio system).
        audioEngine.stop()
        onText = nil
        baseText = ""
    }
}
#endif
