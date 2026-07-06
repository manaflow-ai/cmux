import CmuxAgentChat

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

    /// Shows a non-resizing detail sheet for a compact message row.
    public var showMessageDetail: (ChatMessage) -> Void

    /// Shows a non-resizing detail sheet for a plain-terminal command row.
    public var showTerminalCommandDetail: (TerminalCommandBlock) -> Void

    /// Shows a non-resizing detail sheet for an embedded prose code block.
    public var showCodeBlockDetail: (String, String, String?) -> Void

    /// Creates an action bundle.
    ///
    /// - Parameters:
    ///   - answerOption: Answers the pending actionable card by index.
    ///   - retryPending: Retries a failed pending send by pending id.
    ///   - discardPending: Discards a failed pending send by pending id.
    ///   - openTerminal: Opens the session's raw terminal.
    ///   - showMessageDetail: Presents full details for compact message rows.
    ///   - showTerminalCommandDetail: Presents full details for terminal rows.
    ///   - showCodeBlockDetail: Presents full details for prose code blocks.
    public init(
        answerOption: @escaping (Int) -> Void = { _ in },
        retryPending: @escaping (String) -> Void = { _ in },
        discardPending: @escaping (String) -> Void = { _ in },
        openTerminal: @escaping () -> Void = {},
        showMessageDetail: @escaping (ChatMessage) -> Void = { _ in },
        showTerminalCommandDetail: @escaping (TerminalCommandBlock) -> Void = { _ in },
        showCodeBlockDetail: @escaping (String, String, String?) -> Void = { _, _, _ in }
    ) {
        self.answerOption = answerOption
        self.retryPending = retryPending
        self.discardPending = discardPending
        self.openTerminal = openTerminal
        self.showMessageDetail = showMessageDetail
        self.showTerminalCommandDetail = showTerminalCommandDetail
        self.showCodeBlockDetail = showCodeBlockDetail
    }
}
