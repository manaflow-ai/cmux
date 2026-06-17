/// Whether the Mac currently has an authoritative transcript source for a chat session.
public enum ChatTranscriptAvailability: String, Sendable, Equatable, Codable {
    /// A readable transcript source is known, so an empty page means the conversation is empty.
    case available

    /// The session identity is known, but the transcript file has not been resolved yet.
    case pending
}
