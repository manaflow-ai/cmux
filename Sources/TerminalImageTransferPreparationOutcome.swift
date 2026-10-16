/// What terminal paste preparation produced, and why it produced nothing when
/// an accepted request failed (for example, the worker ran past its deadline).
struct TerminalImageTransferPreparationOutcome: Equatable, Sendable {
    let content: TerminalImageTransferPreparedContent
    /// Nil when the worker returned content, including a `reject`.
    let failure: TerminalPastePreparationFailure?
}
