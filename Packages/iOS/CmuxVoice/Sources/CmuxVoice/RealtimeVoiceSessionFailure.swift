/// User-actionable categories for a GPT Voice Mode session failure.
public enum RealtimeVoiceSessionFailure: Error, Equatable, Sendable {
    /// The user must sign in again.
    case notAuthenticated
    /// The account exceeded its current session budget.
    case rateLimited
    /// Microphone capture or playback could not start.
    case audioUnavailable
    /// The cmux or OpenAI voice service is unavailable.
    case serviceUnavailable
    /// The live Realtime connection ended unexpectedly.
    case connectionLost
}
