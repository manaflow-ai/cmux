public import Foundation

/// The active Task Manager sort column and direction, plus the hierarchical
/// sort algorithm that orders rows within each parent while preserving the
/// outline (parent/child) structure.
public struct CmuxTaskManagerSortOrder: Equatable, Sendable {
    /// A sortable column.
    public enum Column: Equatable, Sendable {
        case name
        case cpu
        case memory
        case processes

        /// The direction first applied when this column becomes active.
        public var defaultDirection: Direction {
            switch self {
            case .name: return .ascending
            case .cpu, .memory, .processes: return .descending
            }
        }
    }

    /// A sort direction.
    public enum Direction: Equatable, Sendable {
        case ascending
        case descending

        /// The opposite direction.
        public var toggled: Direction {
            switch self {
            case .ascending: return .descending
            case .descending: return .ascending
            }
        }
    }

    /// The default order shown on first open: CPU, descending.
    public static let defaultOrder = CmuxTaskManagerSortOrder(column: .cpu, direction: .descending)

    public let column: Column
    public let direction: Direction

    public init(column: Column, direction: Direction) {
        self.column = column
        self.direction = direction
    }

    /// Returns the order produced by clicking `selectedColumn`: toggling
    /// direction if it is already active, otherwise switching to it at its
    /// default direction.
    public func toggled(for selectedColumn: Column) -> CmuxTaskManagerSortOrder {
        if selectedColumn == column {
            return CmuxTaskManagerSortOrder(column: column, direction: direction.toggled)
        }
        return CmuxTaskManagerSortOrder(
            column: selectedColumn,
            direction: selectedColumn.defaultDirection
        )
    }

    /// Sorts a flat outline of rows by the active column/direction while
    /// keeping every child grouped under its parent (stable within ties).
    public func sortedRows(_ rows: [CmuxTaskManagerRow]) -> [CmuxTaskManagerRow] {
        guard !rows.isEmpty else { return rows }
        var index = 0
        let rootLevel = rows.reduce(Int.max) { min($0, $1.level) }
        let nodes = parseNodes(rows, index: &index, level: rootLevel)
        return flatten(sortNodes(nodes))
    }

    private func parseNodes(
        _ rows: [CmuxTaskManagerRow],
        index: inout Int,
        level: Int
    ) -> [SortNode] {
        var nodes: [SortNode] = []
        while index < rows.count {
            let row = rows[index]
            if row.level < level {
                break
            }
            if row.level > level {
                break
            }

            index += 1
            var children: [SortNode] = []
            while index < rows.count, rows[index].level > row.level {
                children.append(contentsOf: parseNodes(rows, index: &index, level: rows[index].level))
            }
            nodes.append(SortNode(row: row, children: children))
        }
        return nodes
    }

    private func sortNodes(_ nodes: [SortNode]) -> [SortNode] {
        let sorted = nodes.enumerated().sorted { lhs, rhs in
            let comparison = compare(lhs.element.row, rhs.element.row)
            if comparison != .orderedSame {
                return direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }

        return sorted.map { _, node in
            SortNode(row: node.row, children: sortNodes(node.children))
        }
    }

    private func flatten(_ nodes: [SortNode]) -> [CmuxTaskManagerRow] {
        nodes.flatMap { node in
            [node.row] + flatten(node.children)
        }
    }

    private func compare(_ lhs: CmuxTaskManagerRow, _ rhs: CmuxTaskManagerRow) -> ComparisonResult {
        switch column {
        case .name:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .cpu:
            return valueComparison(lhs.resources.cpuPercent, rhs.resources.cpuPercent)
        case .memory:
            return valueComparison(lhs.resources.memoryBytes, rhs.resources.memoryBytes)
        case .processes:
            return valueComparison(lhs.resources.processCount, rhs.resources.processCount)
        }
    }

    private func valueComparison<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

/// A node in the temporary tree the hierarchical sort builds from a flat
/// outline: a row plus its already-grouped children. Private to the sort
/// algorithm.
private struct SortNode {
    let row: CmuxTaskManagerRow
    let children: [SortNode]
}
