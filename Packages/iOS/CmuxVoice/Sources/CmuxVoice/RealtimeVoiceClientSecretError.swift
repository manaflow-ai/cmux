/// Failures returned while obtaining a short-lived Realtime credential.
public enum RealtimeVoiceClientSecretError: Error, Equatable, Sendable {
    /// The user does not currently have a valid cmux account session.
    case notAuthenticated
    /// The cmux API base URL is missing or invalid.
    case invalidConfiguration
    /// The account exceeded its Voice Mode session budget.
    case rateLimited
    /// The cmux or OpenAI service could not create a session.
    case serviceUnavailable
    /// The server returned a credential that does not satisfy the client contract.
    case invalidResponse
}
