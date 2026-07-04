#if os(iOS)
@preconcurrency public import AVFoundation
import CmuxMobileSupport
import Foundation
import OSLog
@preconcurrency public import Speech

private let appleVoiceSessionLog = Logger(subsystem: "dev.cmux.ios", category: "apple-voice-session")

/// A ``VoiceTranscriptionSession`` backed by Apple's Speech framework.
public final class AppleVoiceTranscriptionSession: VoiceTranscriptionSession {
    private let recognizer: SFSpeechRecognizer?
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private let continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    private let stream: AsyncStream<VoiceTranscriptionUpdate>

    /// Creates and starts an Apple Speech transcription session.
    public init(recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()) {
        self.recognizer = recognizer
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            self.request.requiresOnDeviceRecognition = true
        }
        let (stream, continuation) = AsyncStream<VoiceTranscriptionUpdate>.makeStream()
        self.stream = stream
        self.continuation = continuation
        guard let recognizer else {
            // No recognizer for this locale/device: without failing here the
            // stream would stay open with no recognition task behind it, so
            // Voice Mode would run the mic forever with no transcript and no error.
            continuation.yield(.failed(L10n.string(
                "mobile.voice.apple.unavailable",
                defaultValue: "Speech recognition isn't available on this device."
            )))
            continuation.finish()
            return
        }
        self.task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeRecognitionResultHandler(continuation: continuation)
        )
    }

    /// Incremental recognition updates.
    public var updates: AsyncStream<VoiceTranscriptionUpdate> { stream }

    /// Feeds a captured audio buffer into Speech.
    /// - Parameter buffer: The captured audio buffer.
    public func streamAudio(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    /// Finishes audio input.
    public func finish() {
        request.endAudio()
    }

    /// Cancels recognition and closes the stream.
    public func cancel() {
        task?.cancel()
        task = nil
        request.endAudio()
        continuation.finish()
    }

    private nonisolated static func makeRecognitionResultHandler(
        continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            let transcript = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFinal = result?.isFinal ?? false
            if let transcript, !transcript.isEmpty {
                continuation.yield(isFinal ? .final(transcript) : .partial(transcript))
            }
            if isFinal {
                continuation.finish()
            }
            if let error {
                // Raw Speech-framework error strings expose internal domains and
                // codes; log the detail and surface cmux-domain copy instead.
                appleVoiceSessionLog.error("Speech recognition failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failed(L10n.string(
                    "mobile.voice.transcription.failed",
                    defaultValue: "Transcription failed. Try again."
                )))
                continuation.finish()
            }
        }
    }
}
#endif
