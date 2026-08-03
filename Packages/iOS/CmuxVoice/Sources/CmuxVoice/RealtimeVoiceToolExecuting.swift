/// Executes the small, app-owned tool surface exposed to GPT Voice Mode.
public protocol RealtimeVoiceToolExecuting: Sendable {
    /// Execute a model-requested action.
    /// - Parameters:
    ///   - call: Constrained tool call decoded by ``RealtimeVoiceSession``.
    ///   - latestUserTranscript: Exact server transcription for the current spoken turn.
    /// - Returns: JSON output for the model and delivery metadata for deduplication.
    func execute(
        _ call: RealtimeVoiceToolCall,
        latestUserTranscript: String?
    ) async -> RealtimeVoiceToolResult
}
