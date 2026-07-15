/// The outcome of validating and submitting a complete command.
///
/// A rejected command never reaches the terminal or its pending-input queue.
public enum TerminalCommandSubmitResult: Equatable, Sendable {
    /// The validated command was passed to the terminal input path.
    case submitted(InputSendResult)

    /// Validation rejected the command before terminal delivery.
    case rejected(TerminalCommandSubmissionRejection)

    /// Whether the command was delivered or queued for an imminently-started surface.
    public var accepted: Bool {
        switch self {
        case .submitted(let result):
            result.accepted
        case .rejected:
            false
        }
    }
}
