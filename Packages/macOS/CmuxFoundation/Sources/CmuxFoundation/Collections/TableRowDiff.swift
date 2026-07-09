public import Foundation

/// The pure decision for applying an ordered list change to a row-based table
/// (e.g. `NSTableView`), computed without any UI dependency.
///
/// Comparing the previous and next row arrays yields one of four outcomes: the
/// lists are equal (no table mutation), the next list extends the previous one
/// by appending rows (insert the tail range), the lists are the same length but
/// some rows differ (reload exactly those rows), or the change is otherwise
/// arbitrary (reload everything). The caller maps each case to the matching
/// table operation; this type owns only the decision, not the application.
public enum TableRowDiff: Equatable, Sendable {
    /// Previous and next rows are equal; the table needs no update.
    case unchanged
    /// Next rows extend previous rows by appending; insert this index range.
    case insertTail(Range<Int>)
    /// Same row count with differing rows; reload exactly these row indices
    /// (an empty set means no row differed and the caller should do nothing).
    case reloadRows(IndexSet)
    /// The change is arbitrary; reload the whole table.
    case reloadAll

    /// Computes the table-row diff between two ordered, equatable row lists.
    public init<Element: Equatable>(previous: [Element], next: [Element]) {
        if previous == next {
            self = .unchanged
            return
        }

        if next.count > previous.count && next.starts(with: previous) {
            self = .insertTail(previous.count..<next.count)
            return
        }

        if next.count == previous.count {
            self = .reloadRows(
                IndexSet(next.indices.filter { next[$0] != previous[$0] })
            )
            return
        }

        self = .reloadAll
    }
}
