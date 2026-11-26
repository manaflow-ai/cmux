import Foundation

/// A structural row change that only drops rows or only adds rows, with the
/// surviving rows in the same relative order. Such edits can be applied with
/// removeRows/insertRows instead of reloading every visible cell.
enum SidebarWorkspaceTableRowEdit: Equatable {
    /// Indexes in the previous row list.
    case remove(IndexSet)
    /// Indexes in the next row list.
    case insert(IndexSet)

    init?<ID: Hashable>(from previous: [ID], to next: [ID]) {
        guard previous != next,
              Set(previous).count == previous.count,
              Set(next).count == next.count else {
            return nil
        }
        if next.count < previous.count,
           let removed = Self.indexesMissing(from: next, in: previous) {
            self = .remove(removed)
        } else if next.count > previous.count,
                  let inserted = Self.indexesMissing(from: previous, in: next) {
            self = .insert(inserted)
        } else {
            return nil
        }
    }

    /// Indexes of `superset` not in `subset`, or nil unless `subset` is an
    /// order-preserving subsequence of `superset`.
    private static func indexesMissing<ID: Equatable>(from subset: [ID], in superset: [ID]) -> IndexSet? {
        var missing = IndexSet()
        var subsetIndex = subset.startIndex
        for (index, id) in superset.enumerated() {
            if subsetIndex < subset.endIndex, subset[subsetIndex] == id {
                subsetIndex += 1
            } else {
                missing.insert(index)
            }
        }
        return subsetIndex == subset.endIndex ? missing : nil
    }
}
