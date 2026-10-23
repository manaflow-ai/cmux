/// The width changes one New Column brings (`layout.newColumnWidth`), from its key's frame to the
/// daemon's layout that has them (``LayoutModel/showNewColumnSizing(_:)``).
///
/// The new column and the widths it gives the others are one gesture: the window shows both in
/// the key's frame and keeps the widths over every daemon snapshot, also while the daemon's
/// column replaces the shown one under a new id, so no frame shows a column springing back. The
/// width intents go once the daemon made the column (``LayoutModel/commitNewColumnSizing(_:)``);
/// a refused column takes them back (``LayoutModel/cancelNewColumnSizing(_:)``).
///
/// ```swift
/// let request = model.prepareNewColumn(nextTo: pane)
/// let sizing = model.showNewColumnSizing(request)
/// // ... the new column's reply:
/// model.commitNewColumnSizing(sizing) // or model.cancelNewColumnSizing(sizing) when it failed
/// ```
public struct PendingColumnSizing: Hashable, Sendable {
    /// The new column's width and the width changes it brings.
    public let request: NewColumnRequest
    /// The one transaction every width change of this New Column carries.
    let transaction: LayoutTransactionID
}
