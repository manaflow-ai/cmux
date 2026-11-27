/// A compact checklist progress readout for sidebar rows and CLI output.
public struct WorkspaceChecklistProgressSummary: Equatable, Sendable {
    /// How many items are completed.
    public let completedCount: Int
    /// How many items exist.
    public let totalCount: Int
    /// The text of the first item that is not completed, if any.
    public let firstUncheckedText: String?

    /// Creates a summary.
    public init(completedCount: Int, totalCount: Int, firstUncheckedText: String?) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.firstUncheckedText = firstUncheckedText
    }
}
