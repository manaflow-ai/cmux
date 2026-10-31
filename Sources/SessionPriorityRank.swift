import Foundation

/// A window's session priority order, most urgent workspace first, built only
/// from the workspace moves the user makes.
///
/// cmux also moves workspaces on its own (notification bumps, new-workspace
/// placement). Those must never change the priority, so the rank records each
/// user *move* (where the moved workspaces landed relative to their
/// neighbours) instead of snapshotting the visible order, which would carry
/// earlier automatic bumps into the rank.
struct SessionPriorityRank: Equatable, Sendable {
    /// Workspace ids in priority order. May still hold ids of closed
    /// workspaces until the next ``sync(visibleOrder:)``.
    private(set) var recordedOrder: [UUID]

    /// Creates a rank from an existing order; repeated ids keep their first slot.
    init(recordedOrder: [UUID] = []) {
        var seen = Set<UUID>()
        self.recordedOrder = recordedOrder.filter { seen.insert($0).inserted }
    }

    /// Appends ids never seen, in visible order. Never drops an id (a
    /// transient remove/insert reorder must not demote a workspace).
    mutating func appendUnseen(visibleOrder: [UUID]) {
        var seen = Set(recordedOrder)
        for id in visibleOrder where seen.insert(id).inserted {
            recordedOrder.append(id)
        }
    }

    /// Drops ids not in `visibleOrder`, then appends unseen ones. Used only
    /// when membership is known stable: after a user move and at restore.
    mutating func sync(visibleOrder: [UUID]) {
        let visible = Set(visibleOrder)
        recordedOrder.removeAll { !visible.contains($0) }
        appendUnseen(visibleOrder: visibleOrder)
    }

    /// The recorded ids that are visible, in recorded order, then the unseen
    /// visible ids in visible order.
    func effectiveOrder(visibleOrder: [UUID]) -> [UUID] {
        let visible = Set(visibleOrder)
        var seen = Set<UUID>()
        var order = recordedOrder.filter { visible.contains($0) && seen.insert($0).inserted }
        for id in visibleOrder where seen.insert(id).inserted {
            order.append(id)
        }
        return order
    }

    /// Records a user move.
    ///
    /// - Parameters:
    ///   - movedIds: The ids the entry point moved.
    ///   - before: The window's visible order before the move.
    ///   - after: The window's visible order after the move.
    ///
    /// Workspaces that moved along with the requested ones (group members
    /// following a dragged anchor) are detected as the ids off a longest
    /// increasing run of `before` positions. Each contiguous run of moved ids
    /// then lands next to its new neighbours in the rank: after its
    /// predecessor or before its successor, whichever is higher for an upward
    /// move and lower for a downward one.
    ///
    /// A move that left the order as it was (to the top where the workspace
    /// already is, below a pinned one, or past the list's edge) affirms the
    /// requested ids' visible place (ruling R24): each run of them is placed
    /// by the rule for the direction the user asked for.
    ///
    /// - Parameter movingUp: Whether the user asked to move the ids up (or to
    ///   a place, such as Move to Top, a drag or `--before`). Read only when
    ///   the order did not change; a move that changed it has its own direction.
    mutating func recordUserMove(movedIds: [UUID], before: [UUID], after: [UUID], movingUp: Bool = true) {
        sync(visibleOrder: after)
        let beforeIndex = Self.indexById(before)
        let afterIndex = Self.indexById(after)
        guard before != after else {
            let affirmed = Set(movedIds.filter { afterIndex[$0] != nil })
            for run in Self.contiguousRuns(of: affirmed, in: after) {
                insert(run: run, movedUp: movingUp, after: after, afterIndex: afterIndex)
            }
            return
        }
        let requested = Set(movedIds)
        let stayed = after.filter { !requested.contains($0) && beforeIndex[$0] != nil }
        let anchored = Self.idsOnLongestIncreasingRun(stayed, positions: beforeIndex)
        var moved = Set(movedIds.filter { beforeIndex[$0] != nil && afterIndex[$0] != nil })
        moved.formUnion(stayed.filter { !anchored.contains($0) })
        for run in Self.contiguousRuns(of: moved, in: after) {
            guard let first = run.first, let firstAfter = afterIndex[first] else { continue }
            let movedUp = firstAfter < (beforeIndex[first] ?? firstAfter)
            insert(run: run, movedUp: movedUp, after: after, afterIndex: afterIndex)
        }
    }

    /// Records an explicit order for some workspaces (batch reorder): they
    /// keep the rank slots they hold, permuted into this order. A full list
    /// therefore becomes the exact order.
    mutating func recordUserOrder(_ orderedIds: [UUID], visibleOrder: [UUID]) {
        sync(visibleOrder: visibleOrder)
        let slotById = Self.indexById(recordedOrder)
        var seen = Set<UUID>()
        let listed = orderedIds.filter { slotById[$0] != nil && seen.insert($0).inserted }
        let slots = listed.compactMap { slotById[$0] }.sorted()
        for (slot, id) in zip(slots, listed) {
            recordedOrder[slot] = id
        }
    }

    // MARK: - Move placement

    /// Places one contiguous run of moved ids next to its new neighbours: as
    /// high as they allow for an upward move, as low for a downward one.
    private mutating func insert(
        run: [UUID],
        movedUp: Bool,
        after: [UUID],
        afterIndex: [UUID: Int]
    ) {
        guard let first = run.first,
              let last = run.last,
              let firstAfter = afterIndex[first],
              let lastAfter = afterIndex[last] else { return }
        let runIds = Set(run)
        var base = recordedOrder
        base.removeAll { runIds.contains($0) }
        let predecessor = firstAfter > 0 ? after[firstAfter - 1] : nil
        let successor = lastAfter + 1 < after.count ? after[lastAfter + 1] : nil
        let afterPredecessor = predecessor.flatMap { base.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let atSuccessor = successor.flatMap { base.firstIndex(of: $0) } ?? base.count
        let insertion = movedUp
            ? min(afterPredecessor, atSuccessor)
            : max(afterPredecessor, atSuccessor)
        base.insert(contentsOf: run, at: insertion)
        recordedOrder = base
    }

    /// Maximal runs of `ids` that sit next to each other in `order`, in `order`.
    private static func contiguousRuns(of ids: Set<UUID>, in order: [UUID]) -> [[UUID]] {
        var runs: [[UUID]] = []
        var current: [UUID] = []
        for id in order {
            if ids.contains(id) {
                current.append(id)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    /// The ids on one longest strictly increasing subsequence of their
    /// `positions` (patience sorting), so ties resolve the same way each time.
    private static func idsOnLongestIncreasingRun(
        _ ids: [UUID],
        positions: [UUID: Int]
    ) -> Set<UUID> {
        let values = ids.map { positions[$0] ?? 0 }
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (offset, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 {
                previous[offset] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(offset)
            } else {
                tails[low] = offset
            }
        }
        var onRun = Set<UUID>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            onRun.insert(ids[cursor])
            cursor = previous[cursor]
        }
        return onRun
    }

    private static func indexById(_ order: [UUID]) -> [UUID: Int] {
        Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
