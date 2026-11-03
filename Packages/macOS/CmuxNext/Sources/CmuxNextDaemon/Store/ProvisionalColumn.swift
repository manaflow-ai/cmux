import Foundation

/// Where a provisional pane opens when it is a new scrolling column (`new-pane-right` with
/// client-minted ids, New Column): after the target pane's column (before it for New Column
/// Left, `side: "left"`), at `width`. Every column there keeps its width (R3b): the new column is
/// new space, and a split-tree screen becomes its full-width column beside it, as in the daemon.
public struct ProvisionalColumn: Sendable, Hashable {
    /// Provisional column handles live far above the daemon's numeric ids, as provisional panes do.
    private static let handleBase: UInt64 = 1 << 62

    /// The new column's handle in the store until the daemon's column replaces it.
    public let handle: ColumnID
    /// The new column's width, a fraction of the viewport.
    public let width: Double
    /// Opens before the target's column (New Column Left, `column-left-v1`) instead of after it.
    public let left: Bool

    /// - Parameters:
    ///   - paneHandle: The provisional pane's handle: the column's handle is derived from it, so
    ///     it is unique for the pane's intent.
    ///   - width: The new column's width (viewport fraction).
    ///   - left: Opens before the target's column instead of after it.
    public init(paneHandle: PaneID, width: Double, left: Bool = false) {
        handle = ColumnID(rawValue: Self.handleBase | paneHandle.rawValue)
        self.width = width
        self.left = left
    }

    /// The tree column's handle (a split-tree screen gets two columns at once).
    var treeHandle: ColumnID { ColumnID(rawValue: handle.rawValue | (1 << 61)) }
}

