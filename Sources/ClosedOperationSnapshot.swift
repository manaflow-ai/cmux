import Foundation

/// One destructive action in the History pane: a group of 1..N closed items that
/// were closed together (a single close, or a multi-select delete). Restoring an
/// operation brings back only its not-yet-live items.
struct ClosedOperationSnapshot: Identifiable, Equatable {
    /// The shared `operationId` of the records in this group.
    let id: UUID
    /// Header label, e.g. "3 workspaces" for a group or the item's title for a singleton.
    let label: String
    /// Most recent close time among the group's items.
    let closedAt: Date
    let items: [ClosedItemHistoryMenuItem]

    var isSingleton: Bool { items.count == 1 }
    /// True when every item in the operation is already restored/live.
    var isFullyRestored: Bool { !items.isEmpty && items.allSatisfy(\.isRestored) }
}
