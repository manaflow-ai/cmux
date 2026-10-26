public import Foundation
public import Observation

/// One Task Manager tab's table: its sort and the row it scrolls back to. Each tab keeps its own
/// over the one shared ``TaskManagerModel`` (a sort in one window's table leaves another window's
/// as it is), and its owner keeps it while the tab's view is discarded, so the view built again
/// sorts and scrolls as before.
///
/// ```swift
/// let table = TaskManagerTableState(sort: "-memory")
/// table.rows(of: model.snapshot) // largest memory first
/// ```
@MainActor @Observable
public final class TaskManagerTableState {
    /// The table's sort (its column headers); empty keeps the sampled order.
    public var sortOrder: [KeyPathComparator<TaskManagerRow>]
    /// A row the table scrolls to the top once a sample lists it (a rebuilt view's saved top row);
    /// cleared when it scrolls.
    public var scrollTarget: ProcessKey?

    /// A table sorted by `sort` (``TaskManagerSort`` text; empty keeps the sampled order).
    public init(sort: String = "", scrollTarget: ProcessKey? = nil) {
        sortOrder = TaskManagerSort.order(sort)
        self.scrollTarget = scrollTarget
    }

    /// The sort as ``TaskManagerSort`` text, which ``init(sort:scrollTarget:)`` reads back.
    public var sort: String { TaskManagerSort.text(sortOrder) }

    /// `snapshot`'s rows in this table's order: the order the table draws them.
    public func rows(of snapshot: TaskManagerSnapshot) -> [TaskManagerRow] {
        sortOrder.isEmpty ? snapshot.rows : snapshot.rows.sorted(using: sortOrder)
    }
}
