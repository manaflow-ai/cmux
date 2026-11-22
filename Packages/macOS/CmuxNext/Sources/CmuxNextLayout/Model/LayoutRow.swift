/// One row of a column: a horizontal band of the column's vertical strip
/// holding one split tree (plans/cmux-next/rows.md).
public nonisolated struct LayoutRow: Hashable, Sendable, Identifiable {
    public var id: RowID
    /// Permille of the column's viewport height, 100...1000 (G1, G2).
    public var height: Int
    public var root: SplitNode

    public static let heightRange: ClosedRange<Int> = 100...1000

    public init(id: RowID, height: Int, root: SplitNode) {
        self.id = id
        self.height = height
        self.root = root
    }
}
