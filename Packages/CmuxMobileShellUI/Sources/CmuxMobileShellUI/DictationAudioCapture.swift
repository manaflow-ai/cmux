#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Owns the speech-recognition audio pipeline OFF the main actor.
///
/// All `AVAudioSession` / `AVAudioEngine` / `SFSpeechRecognizer` work runs on a
/// private serial queue, so the main thread never blocks on
/// `AVAudioSession.setActive` or `AVAudioEngine.start` (each ~100-300ms of audio
/// hardware activation, which is the mic-button press lag when done on
/// `@MainActor`). This is the "less SwiftUI / more UIKit" split: a plain reference
/// type managing the engine, not a `@MainActor @Observable` view model.
///
/// `@unchecked Sendable` is sound because every member is touched only on `queue`
/// (or is immutable), and the non-Sendable AVFoundation/Speech objects never leave
/// this type. Callers receive only `Sendable` value snapshots through the
/// `@Sendable` callbacks and hop to the main actor themselves.
final class DictationAudioCapture: @unchecked Sendable {
    /// Whether a recognizer exists for the current locale. Immutable after init, so
    /// it is safe to read from any thread (the controller reads it on the main
    /// actor to decide the mic button's enabled state).
    let hasRecognizer: Bool

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "dev.cmux.dictation.audio", qos: .userInitiated)

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init() {
        let recognizer = SFSpeechRecognizer()
        self.recognizer = recognizer
        self.hasRecognizer = recognizer != nil
    }

    /// Activate the session, install the tap, and start recognition, all on the
    /// private queue. `onResult` fires for every partial/final result with Sendable
    /// snapshots (transcript, isFinal, failed). `onReady(true)` fires once the
    /// engine is running; `onReady(false)` on any setup failure. Both callbacks run
    /// on the private queue, so the caller hops to the main actor itself.
    func start(
        onResult: @escaping @Sendable (String?, Bool, Bool) -> Void,
        onReady: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            guard let recognizer, recognizer.isAvailable else {
                onReady(false)
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
                // deactivation, so both are omitted; passing them throws on OSes that
                // enforce the documented restrictions.
                try session.setCategory(.record, mode: .measurement)
                try session.setActive(true)
                let format = engine.inputNode.outputFormat(forBus: 0)
                // Validate the format; an invalid one (zero rate/channels, e.g. no
                // usable input route yet) makes `installTap` raise an uncatchable
                // Obj-C exception.
                guard format.channelCount > 0, format.sampleRate > 0 else {
                    onReady(false)
                    return
                }
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    // Realtime audio thread; `append` is thread-safe on the request.
                    request.append(buffer)
                }
                engine.prepare()
                try engine.start()
                self.task = recognizer.recognitionTask(with: request) { result, error in
                    // Arbitrary queue; extract only Sendable snapshots and forward.
                    onResult(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
                }
                onReady(true)
            } catch {
                onReady(false)
            }
        }
    }

    /// Graceful stop: flush buffered audio and stop the engine, but keep the task so
    /// it can still deliver a final result through `onResult`.
    func finishGraceful() {
        queue.async { [self] in
            request?.endAudio()
            stopEngineLocked()
        }
    }

    /// Hard stop: cancel the task, drop the request, and tear the session down.
    func cancel() {
        queue.async { [self] in
            task?.cancel()
            task = nil
            request?.endAudio()
            request = nil
            stopEngineLocked()
        }
    }

    /// Stop the engine, remove the tap, and deactivate the session. Must be called
    /// on `queue`. Safe to call repeatedly.
    private func stopEngineLocked() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
