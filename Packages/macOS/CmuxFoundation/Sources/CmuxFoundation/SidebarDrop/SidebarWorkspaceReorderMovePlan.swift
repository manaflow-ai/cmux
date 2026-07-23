/// One `NSTableView.moveRow(at:to:)` step. Steps apply sequentially; `to` is
/// the destination index after the row is removed from `from` (remove-then-
/// insert semantics), matching how batched table moves are interpreted.
public struct SidebarWorkspaceReorderMoveStep: Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// Plans the `moveRow` steps that turn `current` into `target` when only the
/// dragged block (`movedIds`) changed position: every other id keeps its
/// relative order. Emitting one step per dragged row (instead of one per
/// displaced row) keeps a live-preview update near-linear — O(block × n) with
/// the block bounded by group size — where a per-index greedy walk degrades to
/// O(n²) moves on a full-span drag.
///
/// Returns `nil` unless `target` is exactly such a block permutation of
/// `current`, so a stale or malformed preview order can never desync a table
/// from its data source. The identity order returns no steps.
public struct SidebarWorkspaceReorderMovePlanner: Sendable {
    public init() {}

    public func plan<ID: Hashable>(
        current: [ID],
        target: [ID],
        movedIds: some Sequence<ID>
    ) -> [SidebarWorkspaceReorderMoveStep]? {
        guard current.count == target.count else { return nil }
        guard current != target else { return [] }
        let movedSet = Set(movedIds)
        // Stable rows must agree in content and relative order; the final
        // `live == target` check below then covers the moved rows.
        guard current.filter({ !movedSet.contains($0) }) == target.filter({ !movedSet.contains($0) }) else {
            return nil
        }

        var live = current
        var steps: [SidebarWorkspaceReorderMoveStep] = []
        for targetIndex in target.indices where movedSet.contains(target[targetIndex]) {
            let id = target[targetIndex]
            guard let from = live.firstIndex(of: id) else { return nil }
            live.remove(at: from)
            // Each moved row lands immediately after its target predecessor;
            // processing moved rows in target order makes that placement
            // final because later moves never insert between the two.
            let to: Int
            if targetIndex == 0 {
                to = 0
            } else if let predecessor = live.firstIndex(of: target[targetIndex - 1]) {
                to = predecessor + 1
            } else {
                return nil
            }
            live.insert(id, at: to)
            if from != to {
                steps.append(SidebarWorkspaceReorderMoveStep(from: from, to: to))
            }
        }
        guard live == target else { return nil }
        return steps
    }
}
