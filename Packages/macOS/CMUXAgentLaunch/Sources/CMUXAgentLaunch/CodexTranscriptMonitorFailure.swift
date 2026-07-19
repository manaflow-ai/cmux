/// A failure extracted from a Codex transcript.
public struct CodexTranscriptMonitorFailure: Sendable, Equatable {
    /// The failure classification used to select localized fallback copy.
    public let kind: CodexTranscriptMonitorFailureKind

    /// The primary message, when Codex supplied one.
    public let message: String?

    /// Structured Codex error information rendered as stable JSON or text.
    public let codexErrorInfo: String?

    /// Additional error details rendered as stable JSON or text.
    public let additionalDetails: String?

    /// Whether the failure came from a stream-error event.
    public let isStreamError: Bool

    /// Creates a transcript failure value.
    ///
    /// - Parameters:
    ///   - kind: The failure classification.
    ///   - message: The primary message, if present.
    ///   - codexErrorInfo: Structured Codex error information.
    ///   - additionalDetails: Additional structured details.
    ///   - isStreamError: Whether the failure came from a stream-error event.
    public init(
        kind: CodexTranscriptMonitorFailureKind,
        message: String?,
        codexErrorInfo: String?,
        additionalDetails: String?,
        isStreamError: Bool
    ) {
        self.kind = kind
        self.message = message
        self.codexErrorInfo = codexErrorInfo
        self.additionalDetails = additionalDetails
        self.isStreamError = isStreamError
    }
}
