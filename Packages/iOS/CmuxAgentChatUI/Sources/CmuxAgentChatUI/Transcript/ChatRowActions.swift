/// The closure bundle transcript rows use to act on the conversation.
///
/// Rows receive immutable snapshots plus this bundle — never a reference to
/// the store — so an unrelated store change can't invalidate every row
/// (snapshot-boundary rule).
@MainActor
public struct ChatRowActions {
    /// Answers the pending question or permission card by option index.
    public var answerOption: (Int) -> Void

    /// Retries a failed pending send, keyed by pending id.
    public var retryPending: (String) -> Void

    /// Discards a failed pending send, keyed by pending id.
    public var discardPending: (String) -> Void

    /// Opens the session's raw terminal (the escape hatch).
    public var openTerminal: () -> Void

    /// Creates an action bundle.
    ///
    /// - Parameters:
    ///   - answerOption: Answers the pending actionable card by index.
    ///   - retryPending: Retries a failed pending send by pending id.
    ///   - discardPending: Discards a failed pending send by pending id.
    ///   - openTerminal: Opens the session's raw terminal.
    public init(
        answerOption: @escaping (Int) -> Void = { _ in },
        retryPending: @escaping (String) -> Void = { _ in },
        discardPending: @escaping (String) -> Void = { _ in },
        openTerminal: @escaping () -> Void = {}
    ) {
        self.answerOption = answerOption
        self.retryPending = retryPending
        self.discardPending = discardPending
        self.openTerminal = openTerminal
    }
}
