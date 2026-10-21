import Foundation

/// One recorded note as the ``VoiceNoteOutbox`` stores it next to its audio file.
public struct VoiceNote: Sendable, Codable, Equatable, Identifiable {
    /// Stable id; also the outbox file name stem (`<id>.json`, `<id>.m4a`).
    public var id: UUID
    /// Whether the note came from a call or a plain voice-note request.
    public var mode: ChiefVoiceRequest
    /// When recording started.
    public var createdAt: Date
    /// Recorded length in seconds.
    public var duration: TimeInterval
    /// The on-device transcript; `nil` until transcribed or when transcription failed.
    public var transcript: String?

    /// Creates a note record.
    /// - Parameters:
    ///   - id: The note id (default: a new UUID).
    ///   - mode: The request that recorded it.
    ///   - createdAt: When recording started.
    ///   - duration: Recorded length in seconds.
    ///   - transcript: The transcript, when known.
    public init(id: UUID = UUID(), mode: ChiefVoiceRequest, createdAt: Date, duration: TimeInterval = 0,
                transcript: String? = nil) {
        self.id = id
        self.mode = mode
        self.createdAt = createdAt
        self.duration = duration
        self.transcript = transcript
    }
}
