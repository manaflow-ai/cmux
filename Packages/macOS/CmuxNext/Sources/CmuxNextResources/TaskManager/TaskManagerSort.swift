public import Foundation

/// One column the Task Manager sorts by, and its direction. Its text form (`-cpu,process`: the
/// columns in order, `-` for descending) is what a released page saves, so the page built again
/// sorts as before.
///
/// ```swift
/// let order = TaskManagerSort.order("-memory")
/// TaskManagerSort.text(order) // "-memory"
/// ```
public struct TaskManagerSort: Hashable, Sendable {
    /// A sortable column of the table.
    public enum Column: String, CaseIterable, Sendable {
        case task, process, pid, cpu, memory
    }

    public var column: Column
    public var ascending: Bool

    public init(column: Column, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// The column and direction `comparator` sorts by; nil for a key path no column shows.
    public init?(_ comparator: KeyPathComparator<TaskManagerRow>) {
        guard let column = Column.allCases.first(where: {
            Self(column: $0, ascending: true).comparator.keyPath == comparator.keyPath
        }) else { return nil }
        self.init(column: column, ascending: comparator.order == .forward)
    }

    /// The table's comparator for this column and direction (the one its column header makes).
    public var comparator: KeyPathComparator<TaskManagerRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch column {
        case .task: KeyPathComparator(\TaskManagerRow.task, comparator: String.StandardComparator.localizedStandard, order: order)
        case .process: KeyPathComparator(\TaskManagerRow.name, comparator: String.StandardComparator.localizedStandard, order: order)
        case .pid: KeyPathComparator(\TaskManagerRow.pid, order: order)
        case .cpu: KeyPathComparator(\TaskManagerRow.cpuSortValue, order: order)
        case .memory: KeyPathComparator(\TaskManagerRow.memoryBytes, order: order)
        }
    }

    /// `order` as text; columns no ``Column`` names are left out.
    public static func text(_ order: [KeyPathComparator<TaskManagerRow>]) -> String {
        order.compactMap(Self.init).map { ($0.ascending ? "" : "-") + $0.column.rawValue }.joined(separator: ",")
    }

    /// The order `text` names; unknown columns are left out.
    public static func order(_ text: String) -> [KeyPathComparator<TaskManagerRow>] {
        text.split(separator: ",").compactMap { item in
            let descending = item.hasPrefix("-")
            return Column(rawValue: String(descending ? item.dropFirst() : item))
                .map { Self(column: $0, ascending: !descending).comparator }
        }
    }
}
