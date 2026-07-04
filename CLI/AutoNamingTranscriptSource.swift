/// Source kind for auto-naming transcript extraction diagnostics.
enum AutoNamingTranscriptSource: String, Sendable {
    case claudeTranscript
    case codexRollout
    case grokHistory
    case hookPayload
}
