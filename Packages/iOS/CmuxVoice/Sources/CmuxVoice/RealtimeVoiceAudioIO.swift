public import Foundation

/// Full-duplex 24 kHz mono PCM audio seam for a Realtime voice session.
public protocol RealtimeVoiceAudioIO: Sendable {
    /// Start microphone capture and device playback.
    /// - Returns: A bounded stream of little-endian PCM16 microphone chunks.
    func start() async throws -> AsyncStream<Data>

    /// Stop capture, playback, and the shared audio session.
    func stop() async

    /// Queue one little-endian PCM16 assistant audio chunk for playback.
    /// - Parameters:
    ///   - data: 24 kHz mono PCM16 bytes.
    ///   - itemID: Realtime conversation item that owns the audio.
    func enqueuePlayback(_ data: Data, itemID: String) async

    /// Stop assistant playback for barge-in and return its played duration.
    /// - Returns: Progress for conversation truncation, or `nil` when nothing was playing.
    func interruptPlayback() async -> RealtimeVoicePlaybackProgress?
}
