import Foundation

/// Where a provisional pane opens when it is a new scrolling column (`new-pane-right` with
/// client-minted ids, New Column): after the target pane's column (before it for New Column
/// Left, `side: "left"`), at `width`, with the width changes that opening it brings
/// (`layout.newColumnWidth`) shown in the same turn.
public struct ProvisionalColumn: Sendable, Hashable {
    /// Provisional column handles live far above the daemon's numeric ids, as provisional panes do.
    private static let handleBase: UInt64 = 1 << 62

    /// The new column's handle in the store until the daemon's column replaces it.
    public let handle: ColumnID
    /// The new column's width, a fraction of the viewport.
    public let width: Double
    /// Width changes of existing columns, by handle.
    public let widths: [ColumnID: Double]
    /// The width of the screen's one column while the screen is still a split tree (the daemon
    /// wraps it in a viewport split): the lone full-width column's share beside the new one.
    public let treeWidth: Double?
    /// Opens before the target's column (New Column Left, `column-left-v1`) instead of after it.
    public let left: Bool

    /// - Parameters:
    ///   - paneHandle: The provisional pane's handle: the column's handle is derived from it, so
    ///     it is unique for the pane's intent.
    ///   - width: The new column's width (viewport fraction).
    ///   - widths: Width changes of existing columns.
    ///   - treeWidth: The width of a split-tree screen's one column beside the new one.
    ///   - left: Opens before the target's column instead of after it.
    public init(paneHandle: PaneID, width: Double, widths: [ColumnID: Double] = [:], treeWidth: Double? = nil, left: Bool = false) {
        handle = ColumnID(rawValue: Self.handleBase | paneHandle.rawValue)
        self.width = width
        self.widths = widths
        self.treeWidth = treeWidth
        self.left = left
    }

    /// The tree column's handle (a split-tree screen gets two columns at once).
    var treeHandle: ColumnID { ColumnID(rawValue: handle.rawValue | (1 << 61)) }
}

