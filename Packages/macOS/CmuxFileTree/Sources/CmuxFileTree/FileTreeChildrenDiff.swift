public import Foundation

/// The row changes that turn one sorted child list into another.
///
/// The indices are shaped for `NSOutlineView` batch updates: apply
/// ``removed`` (old coordinates) with `removeItems(at:inParent:)`, then
/// ``inserted`` (new coordinates) with `insertItems(at:inParent:)`, inside
/// one `beginUpdates()`/`endUpdates()` pair. A row whose path survives keeps
/// its identity, so AppKit keeps its selection and expansion; only its cell
/// needs a refresh when ``updated`` lists it.
///
/// ```swift
/// let diff = FileTreeChildrenDiff(old: previous, new: next)
/// outlineView.beginUpdates()
/// outlineView.removeItems(at: diff.removed, inParent: parent, withAnimation: [])
/// outlineView.insertItems(at: diff.inserted, inParent: parent, withAnimation: [])
/// outlineView.endUpdates()
/// ```
public struct FileTreeChildrenDiff: Sendable, Equatable {
    /// Indices into the old list to remove, including rows that moved.
    public let removed: IndexSet
    /// Indices into the new list to insert, including rows that moved.
    public let inserted: IndexSet
    /// Indices into the new list whose path stayed in place but whose entry
    /// changed (size, time, kind). Their cells need reconfiguring.
    public let updated: IndexSet
    /// Paths that moved position. They appear in both ``removed`` and
    /// ``inserted``; the owner reuses the row object so identity survives.
    public let moved: Set<String>

    /// A diff with no changes.
    public static let empty = FileTreeChildrenDiff(removed: [], inserted: [], updated: [], moved: [])

    /// Creates a diff from explicit index sets.
    /// - Parameters:
    ///   - removed: Old-coordinate indices to remove.
    ///   - inserted: New-coordinate indices to insert.
    ///   - updated: New-coordinate indices whose content changed in place.
    ///   - moved: Paths that are removed and re-inserted.
    public init(removed: IndexSet, inserted: IndexSet, updated: IndexSet, moved: Set<String>) {
        self.removed = removed
        self.inserted = inserted
        self.updated = updated
        self.moved = moved
    }

    /// Whether applying the diff changes nothing.
    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }

    /// The number of row insertions and removals, a proxy for AppKit work.
    public var structuralChangeCount: Int { removed.count + inserted.count }

    /// Computes the diff between two child lists, matching rows by path.
    ///
    /// Runs in `O(n log n)`: a path index, then a longest increasing
    /// subsequence over surviving rows to find the fewest moves. Sort-order
    /// changes therefore cost moves only for rows that actually change
    /// relative position.
    /// - Parameters:
    ///   - old: The currently displayed children.
    ///   - new: The children to display.
    public init(old: [FileTreeEntry], new: [FileTreeEntry]) {
        if old == new {
            self = .empty
            return
        }
        if old.isEmpty {
            self.init(removed: [], inserted: IndexSet(integersIn: 0..<new.count), updated: [], moved: [])
            return
        }
        if new.isEmpty {
            self.init(removed: IndexSet(integersIn: 0..<old.count), inserted: [], updated: [], moved: [])
            return
        }
        var oldIndexByPath: [String: Int] = [:]
        oldIndexByPath.reserveCapacity(old.count)
        for (index, entry) in old.enumerated() {
            oldIndexByPath[entry.path] = index
        }

        var removed = IndexSet()
        var inserted = IndexSet()
        var updated = IndexSet()
        var moved = Set<String>()

        // Surviving rows in new order, with their old positions.
        var survivorNewIndices: [Int] = []
        var survivorOldIndices: [Int] = []
        survivorNewIndices.reserveCapacity(min(old.count, new.count))
        survivorOldIndices.reserveCapacity(min(old.count, new.count))
        var survivingOld = IndexSet()
        for (newIndex, entry) in new.enumerated() {
            if let oldIndex = oldIndexByPath[entry.path] {
                survivorNewIndices.append(newIndex)
                survivorOldIndices.append(oldIndex)
                survivingOld.insert(oldIndex)
            } else {
                inserted.insert(newIndex)
            }
        }
        removed = IndexSet(integersIn: 0..<old.count).subtracting(survivingOld)

        let stable = Self.longestIncreasingSubsequence(survivorOldIndices)
        for position in survivorOldIndices.indices {
            let oldIndex = survivorOldIndices[position]
            let newIndex = survivorNewIndices[position]
            if stable.contains(position) {
                if old[oldIndex] != new[newIndex] {
                    updated.insert(newIndex)
                }
            } else {
                removed.insert(oldIndex)
                inserted.insert(newIndex)
                moved.insert(new[newIndex].path)
            }
        }
        self.init(removed: removed, inserted: inserted, updated: updated, moved: moved)
    }

    /// Positions (into `values`) of one longest strictly increasing subsequence.
    private static func longestIncreasingSubsequence(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        // Fast path: already increasing, the common case for plain inserts and removals.
        var isIncreasing = true
        for index in 1..<values.count where values[index] <= values[index - 1] {
            isIncreasing = false
            break
        }
        if isIncreasing { return Set(values.indices) }

        var tailPositions: [Int] = []
        var predecessor = [Int](repeating: -1, count: values.count)
        for position in values.indices {
            let value = values[position]
            var low = 0
            var high = tailPositions.count
            while low < high {
                let mid = (low + high) / 2
                if values[tailPositions[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessor[position] = tailPositions[low - 1] }
            if low == tailPositions.count {
                tailPositions.append(position)
            } else {
                tailPositions[low] = position
            }
        }
        var result = Set<Int>()
        var cursor = tailPositions.last ?? -1
        while cursor >= 0 {
            result.insert(cursor)
            cursor = predecessor[cursor]
        }
        return result
    }
}
