#if os(iOS)
@preconcurrency public import AVFoundation
import Foundation
@preconcurrency public import Speech

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
        self.task = recognizer?.recognitionTask(
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
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
            }
        }
    }
}
#endif
