#if os(iOS)
import AVFoundation
import Foundation
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
/// base + transcript (see ``ComposerDictationTextMerge``) so dictation appends to
/// whatever the user already typed and never clobbers it.
///
/// Concurrency: the type is `@MainActor`, so all published state and the `onText`
/// callback mutate the store on the main actor. Speech / AVFoundation deliver
/// their recognition callbacks on an arbitrary queue, so the result handler hops
/// back to the main actor before touching any state, and captures `self` weakly
/// to avoid a retain cycle through the recognition task.
@MainActor
final class ComposerDictationController: ObservableObject {
    /// The current point in the dictation state machine. Drives the mic button's
    /// enabled/listening presentation.
    @Published private(set) var state: ComposerDictationState = .idle

    /// The recognizer for the user's locale. `nil` when the locale is
    /// unsupported, which is surfaced as ``ComposerDictationState/unavailable``.
    private let recognizer: SFSpeechRecognizer?

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

    /// The callback that writes merged text back into the composer. Held only
    /// while listening; cleared on teardown so a late callback cannot mutate the
    /// store after the user left.
    private var onText: ((String) -> Void)?

    init() {
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

    /// Toggle dictation: start if idle, stop if already listening.
    ///
    /// - Parameters:
    ///   - existingText: The composer's current text, captured as the merge base.
    ///   - onText: Receives merged text (base + transcript) on the main actor for
    ///     every partial and the final result.
    func toggle(existingText: String, onText: @escaping (String) -> Void) {
        if state.isListening {
            stop()
        } else {
            start(existingText: existingText, onText: onText)
        }
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
        state = .requestingPermission
        requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                // Denied or restricted: a terminal rest state that disables the
                // mic. The captured callback is dropped.
                self.onText = nil
                self.state = .unavailable
                return
            }
            // A second tap (stop) may have landed while authorization resolved.
            guard self.state == .requestingPermission else { return }
            self.beginRecognition()
        }
    }

    /// Stop dictation and tear everything down: cancel the task, end the request,
    /// remove the audio tap, stop the engine, and deactivate the audio session.
    /// Idempotent and safe to call from any teardown point (second tap, send,
    /// focus loss, `onDisappear`, terminal switch).
    func stop() {
        if state == .listening { state = .stopping }
        teardown()
        // Preserve a terminal `unavailable`; otherwise return to idle. A stop from
        // an already-idle state is a harmless no-op (teardown is all nil-checks).
        if state != .unavailable {
            state = .idle
        }
    }

    // MARK: - Authorization

    /// Resolve both speech-recognition and microphone authorization, calling back
    /// on the main actor with whether BOTH were granted.
    private func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            // The Speech callback arrives off the main actor; hop back before
            // touching any state or the microphone request.
            Task { @MainActor in
                guard speechStatus == .authorized else {
                    completion(false)
                    return
                }
                Self.requestMicrophonePermission { micGranted in
                    completion(micGranted)
                }
            }
        }
    }

    /// Request microphone permission, bridging the iOS 17+ API to its
    /// pre-17 fallback. Calls back on the main actor.
    private static func requestMicrophonePermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                Task { @MainActor in completion(granted) }
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
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            failStart()
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero-channel format means there is no usable input route; bail rather
        // than crash installing a tap with an invalid format.
        guard format.channelCount > 0 else {
            failStart()
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            // The tap fires on a realtime audio thread. `append` is thread-safe on
            // the request; do not touch main-actor state here.
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            failStart()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The recognition callback arrives on an arbitrary queue with
            // non-Sendable reference types (`SFSpeechRecognitionResult`, `Error`).
            // Extract only Sendable value snapshots HERE, then hop to the main
            // actor with those, so no non-Sendable reference crosses the actor
            // boundary. `self` is weak so the task does not retain the controller.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let transcript {
                    self.onText?(ComposerDictationTextMerge.merged(
                        base: self.baseText,
                        transcript: transcript
                    ))
                }
                // A final result or an error (end-of-stream, recognition failure)
                // tears down so the mic does not stay hot.
                if isFinal || failed {
                    self.stop()
                }
            }
        }

        state = .listening
    }

    /// Tear down after a setup failure and disable the mic. Distinct from a clean
    /// stop because a failed start indicates the recognizer cannot be used right
    /// now (no input route, session error, recognizer offline).
    private func failStart() {
        teardown()
        state = .unavailable
    }

    /// Cancel the recognition task, end and drop the request, remove the audio
    /// tap, stop the engine, deactivate the audio session, and clear the
    /// callback. Safe to call repeatedly; every reference is nil-checked.
    private func teardown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        // The tap must be removed whether or not the engine was running, so a
        // failed start that installed the tap before `start()` threw does not
        // leak it onto the input node.
        audioEngine.inputNode.removeTap(onBus: 0)
        onText = nil
        baseText = ""
        // Deactivate the audio session so other audio (and the system) reclaim it.
        // Failure here is non-fatal: the engine is already stopped.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
