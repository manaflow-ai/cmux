/// A content-loading refusal that the diff expander can present distinctly.
public enum DiffExpansionContentError: Error, Sendable, Equatable {
    /// The current file exceeds the reader's safe expansion byte limit.
    case tooLarge
}
