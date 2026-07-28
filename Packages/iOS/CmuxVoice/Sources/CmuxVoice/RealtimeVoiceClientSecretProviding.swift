/// Supplies server-minted credentials for OpenAI Realtime sessions.
public protocol RealtimeVoiceClientSecretProviding: Sendable {
    /// Fetch a fresh short-lived credential.
    /// - Returns: A credential that has not yet expired.
    /// - Throws: ``RealtimeVoiceClientSecretError`` when authentication or the service is unavailable.
    func fetchClientSecret() async throws -> RealtimeVoiceClientSecret
}
