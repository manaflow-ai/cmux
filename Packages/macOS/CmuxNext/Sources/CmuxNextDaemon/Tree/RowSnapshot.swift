import Foundation

/// One row of a column (`rows-v1`, `Screen.columns[].rows[]`): a horizontal
/// band of the column's vertical strip holding one split tree.
public struct RowSnapshot: Sendable, Hashable, Decodable {
    public var id: RowID
    /// Permille of the column's viewport height, 100...1000. The sum per
    /// column is free: at most 1000 fills the column, more scrolls it.
    public var height: Int
    /// The split tree inside the row.
    public var layout: LayoutNode

    public init(id: RowID, height: Int, layout: LayoutNode) {
        self.id = id
        self.height = height
        self.layout = layout
    }
}
