/// Source kind for auto-naming transcript extraction diagnostics.
enum AutoNamingTranscriptSource: String, Sendable {
    case claudeTranscript
    case codexRollout
    case grokHistory
    case hookPayload
}

/// Diagnostics from parsing an agent transcript or hook payload.
struct AutoNamingTranscriptExtraction: Equatable, Sendable {
    var source: AutoNamingTranscriptSource
    var messages: [AutoNamingTranscriptMessage]
    var recordCount: Int
    var malformedRecordCount: Int
    var skippedRecordCount: Int

    var hasFailures: Bool {
        malformedRecordCount > 0 || (recordCount > 0 && messages.isEmpty)
    }

    var diagnosticSummary: String? {
        guard hasFailures else { return nil }
        return "\(source.rawValue): messages=\(messages.count) records=\(recordCount) malformed=\(malformedRecordCount) skipped=\(skippedRecordCount)"
    }
}
