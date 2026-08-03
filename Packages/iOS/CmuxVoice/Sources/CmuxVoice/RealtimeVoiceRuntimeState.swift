/// Renderable lifecycle state for GPT Voice Mode.
public enum RealtimeVoiceRuntimeState: Equatable, Sendable {
    /// No session owns the microphone.
    case idle
    /// Credentials, audio, and the Realtime connection are starting.
    case connecting
    /// The session is listening for the next user turn.
    case listening
    /// The assistant is speaking.
    case speaking
    /// A terminal inventory or delivery tool is running.
    case working
    /// The session stopped because of a classified failure.
    case failed
}
