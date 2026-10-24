import Foundation

/// Where a provisional pane opens when it is a new row (`new-row` with client-minted ids, New
/// Row): below the target pane's row in its column, at `height` permille.
public struct ProvisionalRow: Sendable, Hashable {
    /// Provisional row handles live far above the daemon's numeric ids.
    private static let handleBase: UInt64 = 1 << 62

    /// The new row's handle until the daemon's row replaces it.
    public let handle: RowID
    /// The new row's height, permille of the column's viewport height (100...1000).
    public let height: Int

    /// - Parameters:
    ///   - paneHandle: The provisional pane's handle; the row's handle derives from it.
    ///   - height: The new row's height in permille.
    public init(paneHandle: PaneID, height: Int) {
        handle = RowID(rawValue: Self.handleBase | paneHandle.rawValue)
        self.height = height
    }

    /// The first row's handle of a column that had no rows (it gets two at once).
    var firstHandle: RowID { RowID(rawValue: handle.rawValue | (1 << 61)) }
}
