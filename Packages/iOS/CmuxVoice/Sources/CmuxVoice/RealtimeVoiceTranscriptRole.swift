/// Speaker represented by one GPT Voice Mode transcript entry.
public enum RealtimeVoiceTranscriptRole: Equatable, Sendable {
    /// Spoken iPhone user input.
    case user
    /// Spoken GPT response.
    case assistant
}
