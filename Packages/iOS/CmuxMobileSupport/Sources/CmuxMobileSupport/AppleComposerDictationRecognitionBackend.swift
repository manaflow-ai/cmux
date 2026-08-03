#if os(iOS)
@preconcurrency public import AVFoundation
import Foundation
@preconcurrency public import Speech

/// Apple's Speech-framework backend for composer dictation.
@MainActor
public final class AppleComposerDictationRecognitionBackend: ComposerDictationRecognitionBackend {
    private let recognizer: SFSpeechRecognizer?
    private let contextualStrings: [String]
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Creates an Apple Speech backend.
    /// - Parameters:
    ///   - recognizer: The speech recognizer to use. Defaults to the current locale.
    ///   - contextualStrings: Terms to bias Apple Speech recognition toward.
    public init(
        recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(),
        contextualStrings: [String] = []
    ) {
        self.recognizer = recognizer
        self.contextualStrings = contextualStrings
    }

    /// Whether the user's locale has a recognizer.
    public var isSupported: Bool {
        recognizer != nil
    }

    /// Whether the recognizer is currently available.
    public var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    /// Reads Speech + microphone permission without invoking TCC callbacks.
    public nonisolated func resolvedAuthorization() -> ComposerDictationAuthorizationResolution {
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

    /// Requests Speech authorization followed by microphone authorization.
    public nonisolated func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                completion(false)
                return
            }
            Self.requestMicrophonePermission(completion)
        }
    }

    /// Builds the audio tap block and its backing Speech request.
    /// - Returns: A tap closure that appends captured buffers to Speech.
    public func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // `nonisolated(unsafe)`-safe: `append(_:)` is thread-safe, weak, never outlives the request.
        nonisolated(unsafe) weak let weakRequest: SFSpeechAudioBufferRecognitionRequest? = request
        return { buffer, _ in
            weakRequest?.append(buffer)
        }
    }

    /// Starts the Speech recognition task.
    /// - Parameter resultHandler: Receives transcript/final/failure events.
    public func start(resultHandler: @escaping @MainActor (ComposerDictationRecognitionUpdate) -> Void) {
        guard let recognizer, let request else {
            resultHandler(.failed)
            return
        }
        task = recognizer.recognitionTask(
            with: request,
            resultHandler: makeRecognitionResultHandler(resultHandler: resultHandler)
        )
    }

    /// Flushes buffered audio for graceful finalization.
    public func endAudio() {
        request?.endAudio()
    }

    /// Cancels Speech recognition and drops the request.
    public func cancel() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

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

    private nonisolated func makeRecognitionResultHandler(
        resultHandler: @escaping @MainActor (ComposerDictationRecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                if let transcript, !transcript.isEmpty {
                    resultHandler(.transcript(transcript, isFinal: isFinal))
                } else if isFinal {
                    resultHandler(.finished)
                }
                if failed {
                    resultHandler(.failed)
                }
            }
        }
    }
}
#endif
