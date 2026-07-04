@preconcurrency public import AVFoundation

/// Runtime speech-recognition session shared by composer dictation and Voice Mode.
public protocol VoiceTranscriptionSession: AnyObject {
    /// Incremental recognition updates.
    var updates: AsyncStream<VoiceTranscriptionUpdate> { get }

    /// Feeds a captured audio buffer into the recognizer.
    /// - Parameter buffer: The microphone buffer captured by the app audio engine.
    func streamAudio(_ buffer: AVAudioPCMBuffer)

    /// Finishes audio input and emits a final transcript when available.
    func finish()

    /// Cancels recognition and closes update streams.
    func cancel()
}
