/// Semantic kind of one compact turn activity item.
public enum TranscriptActivityKind: Hashable, Sendable {
    /// Earlier assistant prose demoted by a later answer.
    case assistant
    /// Agent reasoning.
    case thought
    /// Terminal or shell command.
    case command
    /// Non-terminal tool invocation.
    case tool
    /// File mutation.
    case file
    /// Agent question.
    case question
    /// Permission request.
    case permission
    /// Session status event.
    case status
    /// Attachment event.
    case attachment
    /// Future activity presented without exposing its raw record kind.
    case unknown
}
