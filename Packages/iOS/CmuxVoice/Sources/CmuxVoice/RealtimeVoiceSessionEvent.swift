/// Observable events emitted by a live GPT Voice Mode session.
public enum RealtimeVoiceSessionEvent: Equatable, Sendable {
    /// The OpenAI Realtime session accepted its configuration.
    case connected
    /// Incremental transcript text for the current user turn.
    case userTranscriptDelta(String)
    /// Final transcript text for a user turn.
    case userTranscriptCompleted(String)
    /// Incremental transcript text for the assistant response.
    case assistantTranscriptDelta(String)
    /// Final transcript text for the assistant response.
    case assistantTranscriptCompleted(String)
    /// The assistant started emitting spoken audio.
    case assistantSpeechStarted
    /// The assistant finished emitting spoken audio.
    case assistantSpeechEnded
    /// A terminal inventory or delivery tool is running.
    case toolActivity(Bool)
    /// The session failed.
    case failed(RealtimeVoiceSessionFailure)
    /// The session stopped.
    case disconnected
}
