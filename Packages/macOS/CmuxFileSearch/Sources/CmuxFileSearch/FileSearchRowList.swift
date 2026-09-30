public import Foundation

/// The results as the flat list of rows a table shows: each file row
/// followed by its match rows unless the file is collapsed.
///
/// A flat table replaces an outline because `NSOutlineView` expansion is
/// linear in the rows below the item, so expanding each streamed file costs
/// seconds at 100k matches. Appending rows to a table is constant time per
/// row; collapsing rebuilds the list, which is linear once per user action.
public final class FileSearchRowList {
    public private(set) var rows: [FileSearchResultPosition] = []
    private let tree: FileSearchResultTree

    public init(tree: FileSearchResultTree) {
        self.tree = tree
    }

    public var count: Int { rows.count }

    public enum Update: Equatable {
        /// Rows were appended at the end; `refreshedRows` are file rows whose
        /// match count changed.
        case appended(inserted: Range<Int>, refreshedRows: IndexSet)
        /// Rows moved; reload everything.
        case reload
    }

    /// Rebuilds every row from the tree.
    public func rebuild() {
        var next: [FileSearchResultPosition] = []
        next.reserveCapacity(tree.fileCount + tree.matchCount)
        for (fileIndex, file) in tree.files.enumerated() {
            next.append(FileSearchResultPosition(fileIndex: fileIndex, matchIndex: nil))
            guard file.isExpanded else { continue }
            for matchIndex in file.matches.indices {
                next.append(FileSearchResultPosition(fileIndex: fileIndex, matchIndex: matchIndex))
            }
        }
        rows = next
    }

    /// Applies a tree change. Streamed output appends at the end, except
    /// when a file other than the last one gains matches, which reloads.
    public func apply(_ change: FileSearchTreeChange) -> Update {
        var refreshed = IndexSet()
        let start = rows.count
        let lastFileIndex = rows.last?.fileIndex
        for grown in change.grownFiles {
            guard grown.fileIndex == lastFileIndex else {
                rebuild()
                return .reload
            }
            let file = tree.files[grown.fileIndex]
            if let fileRow = rows.lastIndex(where: { $0.fileIndex == grown.fileIndex && $0.matchIndex == nil }) {
                refreshed.insert(fileRow)
            }
            guard file.isExpanded else { continue }
            for matchIndex in grown.previousCount..<file.matches.count {
                rows.append(FileSearchResultPosition(fileIndex: grown.fileIndex, matchIndex: matchIndex))
            }
        }
        for fileIndex in change.insertedFiles {
            rows.append(FileSearchResultPosition(fileIndex: fileIndex, matchIndex: nil))
            let file = tree.files[fileIndex]
            guard file.isExpanded else { continue }
            for matchIndex in file.matches.indices {
                rows.append(FileSearchResultPosition(fileIndex: fileIndex, matchIndex: matchIndex))
            }
        }
        return .appended(inserted: start..<rows.count, refreshedRows: refreshed)
    }

    /// The row showing `position`, if visible. Binary search over the
    /// ordered rows.
    public func row(of position: FileSearchResultPosition) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(rows[mid], position) { low = mid + 1 } else { high = mid }
        }
        guard low < rows.count, rows[low] == position else { return nil }
        return low
    }

    /// The file row at or above `row`.
    public func fileRow(containing row: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        return self.row(of: FileSearchResultPosition(fileIndex: rows[row].fileIndex, matchIndex: nil))
    }

    private static func precedes(_ lhs: FileSearchResultPosition, _ rhs: FileSearchResultPosition) -> Bool {
        if lhs.fileIndex != rhs.fileIndex { return lhs.fileIndex < rhs.fileIndex }
        return (lhs.matchIndex ?? -1) < (rhs.matchIndex ?? -1)
    }
}
