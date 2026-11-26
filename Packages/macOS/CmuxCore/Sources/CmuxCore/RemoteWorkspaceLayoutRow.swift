/// Indices into the original placement array for one pane and its hidden tabs.
public struct RemoteWorkspaceLayoutRow: Equatable, Sendable {
    /// Source-array index of the tab shown by the pane.
    public let shownIndex: Int
    /// Source-array indices of the remaining tabs, in tab order.
    public let hiddenIndices: [Int]

    /// Creates a row from indices selected by the workspace planner.
    nonisolated init(shownIndex: Int, hiddenIndices: [Int]) {
        self.shownIndex = shownIndex
        self.hiddenIndices = hiddenIndices
    }
}
