import Foundation

/// Records the microphone into a file. The iOS adapter wraps `AVAudioRecorder`.
public protocol VoiceRecording: Sendable {
    /// Starts recording AAC audio into `url` (the outbox's audio path for the note).
    /// - Throws: When the audio session or recorder cannot start.
    func start(writingTo url: URL) async throws
    /// Stops recording and returns the recorded length in seconds.
    func stop() async -> TimeInterval
}
