import Foundation

/// One immutable input value with a stable identity in an AppKit sidebar.
struct SidebarAppKitSnapshotItem<ItemID: Hashable, Input: Equatable>: Equatable {
    let id: ItemID
    let input: Input
}

/// An ordered, immutable input snapshot for ``SidebarAppKitSnapshotStore``.
///
/// Item ids must be unique. A presentation update replaces the input associated
/// with an existing id; structural identity changes only through a new snapshot.
struct SidebarAppKitSnapshot<ItemID: Hashable, Input: Equatable>: Equatable {
    let items: [SidebarAppKitSnapshotItem<ItemID, Input>]
    let itemIDs: [ItemID]

    init(items: [SidebarAppKitSnapshotItem<ItemID, Input>]) {
        var seen = Set<ItemID>()
        seen.reserveCapacity(items.count)
        for item in items {
            precondition(
                seen.insert(item.id).inserted,
                "SidebarAppKitSnapshot item ids must be unique"
            )
        }
        self.items = items
        itemIDs = items.map(\.id)
    }
}

/// Presentation-only context owned by the AppKit sidebar state engine.
struct SidebarAppKitProjectionContext: Equatable {
    let isHovered: Bool
}

/// One identity-preserving row move in a structural snapshot diff.
struct SidebarAppKitSnapshotMove<ItemID: Hashable>: Equatable {
    let itemID: ItemID
    let fromRow: Int
    let toRow: Int
}

/// AppKit-ready structural and presentation changes between two snapshots.
///
/// Removal rows use the old ordering. Insert, move destinations, and reload
/// rows use the new ordering, so a table or outline view can apply structural
/// changes before reloading the final row indexes.
struct SidebarAppKitSnapshotDiff<ItemID: Hashable>: Equatable {
    var insertedItemIDs: Set<ItemID> = []
    var removedItemIDs: Set<ItemID> = []
    var movedItemIDs: Set<ItemID> = []
    var reloadedItemIDs: Set<ItemID> = []
    var insertedRows = IndexSet()
    var removedRows = IndexSet()
    var moves: [SidebarAppKitSnapshotMove<ItemID>] = []
    var reloadedRows = IndexSet()

    var isEmpty: Bool {
        insertedItemIDs.isEmpty &&
            removedItemIDs.isEmpty &&
            movedItemIDs.isEmpty &&
            reloadedItemIDs.isEmpty
    }
}

/// Deterministic work counters for scale tests and signpost adapters.
struct SidebarAppKitSnapshotStoreInstrumentation: Equatable {
    var structuralSnapshotApplyCount = 0
    var keyedPresentationUpdateCount = 0
    var hoverTransitionCount = 0
    var totalItemVisitCount = 0
    var totalProjectionCount = 0
    var totalReloadCount = 0
    var lastOperationItemVisitCount = 0
    var lastOperationProjectionCount = 0
    var lastOperationReloadCount = 0
}

/// Main-thread state engine for an AppKit workspace table or outline view.
///
/// The store owns no live models and uses no observation framework. Callers
/// submit immutable input values. Structural snapshots are diffed by stable id,
/// while a keyed presentation update performs one dictionary lookup and one
/// projection independent of the total item count.
@MainActor
final class SidebarAppKitSnapshotStore<ItemID: Hashable, Input: Equatable, Presentation: Equatable> {
    typealias Item = SidebarAppKitSnapshotItem<ItemID, Input>
    typealias Snapshot = SidebarAppKitSnapshot<ItemID, Input>
    typealias Diff = SidebarAppKitSnapshotDiff<ItemID>
    typealias Projector = (ItemID, Input, SidebarAppKitProjectionContext) -> Presentation

    private struct Entry {
        var input: Input
        var presentation: Presentation
    }

    private let projector: Projector
    private var entriesByItemID: [ItemID: Entry] = [:]
    private var rowIndexByItemID: [ItemID: Int] = [:]

    private(set) var orderedItemIDs: [ItemID] = []
    private(set) var hoveredItemID: ItemID?
    private(set) var instrumentation = SidebarAppKitSnapshotStoreInstrumentation()
    private(set) var lastProjectedItemIDs: Set<ItemID> = []

    init(snapshot: Snapshot, projector: @escaping Projector) {
        self.projector = projector
        orderedItemIDs = snapshot.itemIDs
        entriesByItemID.reserveCapacity(snapshot.items.count)
        rowIndexByItemID.reserveCapacity(snapshot.items.count)

        for (row, item) in snapshot.items.enumerated() {
            recordItemVisit()
            entriesByItemID[item.id] = Entry(
                input: item.input,
                presentation: project(itemID: item.id, input: item.input)
            )
            rowIndexByItemID[item.id] = row
        }
    }

    var itemCount: Int { orderedItemIDs.count }

    func contains(_ itemID: ItemID) -> Bool {
        entriesByItemID[itemID] != nil
    }

    func itemID(atRow row: Int) -> ItemID? {
        guard orderedItemIDs.indices.contains(row) else { return nil }
        return orderedItemIDs[row]
    }

    func rowIndex(for itemID: ItemID) -> Int? {
        rowIndexByItemID[itemID]
    }

    func input(for itemID: ItemID) -> Input? {
        entriesByItemID[itemID]?.input
    }

    func presentation(for itemID: ItemID) -> Presentation? {
        entriesByItemID[itemID]?.presentation
    }

    func presentation(atRow row: Int) -> Presentation? {
        guard let itemID = itemID(atRow: row) else { return nil }
        return entriesByItemID[itemID]?.presentation
    }

    /// Applies an ordered immutable snapshot and returns a minimal identity diff.
    /// Unchanged inputs reuse their existing presentations without projection.
    @discardableResult
    func apply(snapshot: Snapshot) -> Diff {
        beginOperation()
        instrumentation.structuralSnapshotApplyCount += 1

        var diff = structuralDiff(from: orderedItemIDs, to: snapshot.itemIDs)
        var nextEntries: [ItemID: Entry] = [:]
        nextEntries.reserveCapacity(snapshot.items.count)
        var nextRowIndexByItemID: [ItemID: Int] = [:]
        nextRowIndexByItemID.reserveCapacity(snapshot.items.count)

        for (row, item) in snapshot.items.enumerated() {
            recordItemVisit()
            nextRowIndexByItemID[item.id] = row

            if let existing = entriesByItemID[item.id], existing.input == item.input {
                nextEntries[item.id] = existing
                continue
            }

            let nextPresentation = project(itemID: item.id, input: item.input)
            if let existing = entriesByItemID[item.id],
               existing.presentation != nextPresentation {
                diff.reloadedItemIDs.insert(item.id)
                diff.reloadedRows.insert(row)
            }
            nextEntries[item.id] = Entry(
                input: item.input,
                presentation: nextPresentation
            )
        }

        if let hoveredItemID, nextEntries[hoveredItemID] == nil {
            self.hoveredItemID = nil
        }
        orderedItemIDs = snapshot.itemIDs
        entriesByItemID = nextEntries
        rowIndexByItemID = nextRowIndexByItemID
        finishOperation(diff: diff)
        return diff
    }

    /// Replaces one immutable input and reprojects only its keyed presentation.
    /// The operation is O(1) apart from caller-owned projection work.
    @discardableResult
    func updatePresentation(for itemID: ItemID, input: Input) -> Diff {
        beginOperation()
        instrumentation.keyedPresentationUpdateCount += 1

        guard var entry = entriesByItemID[itemID],
              let row = rowIndexByItemID[itemID] else {
            let diff = Diff()
            finishOperation(diff: diff)
            return diff
        }

        recordItemVisit()
        guard entry.input != input else {
            let diff = Diff()
            finishOperation(diff: diff)
            return diff
        }

        let nextPresentation = project(itemID: itemID, input: input)
        entry.input = input
        var diff = Diff()
        if entry.presentation != nextPresentation {
            entry.presentation = nextPresentation
            diff.reloadedItemIDs.insert(itemID)
            diff.reloadedRows.insert(row)
        }
        entriesByItemID[itemID] = entry
        finishOperation(diff: diff)
        return diff
    }

    /// Reprojects only the old and new hovered rows. Unknown ids normalize to nil.
    @discardableResult
    func setHoveredItemID(_ requestedItemID: ItemID?) -> Diff {
        beginOperation()
        let nextHoveredItemID = requestedItemID.flatMap { itemID in
            entriesByItemID[itemID] == nil ? nil : itemID
        }
        guard nextHoveredItemID != hoveredItemID else {
            let diff = Diff()
            finishOperation(diff: diff)
            return diff
        }

        instrumentation.hoverTransitionCount += 1
        let previousHoveredItemID = hoveredItemID
        hoveredItemID = nextHoveredItemID
        var affectedItemIDs: [ItemID] = []
        if let previousHoveredItemID {
            affectedItemIDs.append(previousHoveredItemID)
        }
        if let nextHoveredItemID, nextHoveredItemID != previousHoveredItemID {
            affectedItemIDs.append(nextHoveredItemID)
        }

        var diff = Diff()
        for itemID in affectedItemIDs {
            guard var entry = entriesByItemID[itemID],
                  let row = rowIndexByItemID[itemID] else { continue }
            recordItemVisit()
            let nextPresentation = project(itemID: itemID, input: entry.input)
            guard entry.presentation != nextPresentation else { continue }
            entry.presentation = nextPresentation
            entriesByItemID[itemID] = entry
            diff.reloadedItemIDs.insert(itemID)
            diff.reloadedRows.insert(row)
        }
        finishOperation(diff: diff)
        return diff
    }

    func resetInstrumentation() {
        instrumentation = SidebarAppKitSnapshotStoreInstrumentation()
        lastProjectedItemIDs.removeAll(keepingCapacity: true)
    }

    private func structuralDiff(from oldItemIDs: [ItemID], to newItemIDs: [ItemID]) -> Diff {
        let difference = newItemIDs.difference(from: oldItemIDs).inferringMoves()
        var diff = Diff()

        for change in difference {
            switch change {
            case .remove(let offset, let itemID, let associatedWith):
                if let destination = associatedWith {
                    diff.movedItemIDs.insert(itemID)
                    diff.moves.append(
                        SidebarAppKitSnapshotMove(
                            itemID: itemID,
                            fromRow: offset,
                            toRow: destination
                        )
                    )
                } else {
                    diff.removedItemIDs.insert(itemID)
                    diff.removedRows.insert(offset)
                }
            case .insert(let offset, let itemID, let associatedWith):
                guard associatedWith == nil else { continue }
                diff.insertedItemIDs.insert(itemID)
                diff.insertedRows.insert(offset)
            }
        }

        diff.moves.sort { lhs, rhs in
            if lhs.fromRow == rhs.fromRow {
                return lhs.toRow < rhs.toRow
            }
            return lhs.fromRow < rhs.fromRow
        }
        return diff
    }

    private func beginOperation() {
        instrumentation.lastOperationItemVisitCount = 0
        instrumentation.lastOperationProjectionCount = 0
        instrumentation.lastOperationReloadCount = 0
        lastProjectedItemIDs.removeAll(keepingCapacity: true)
    }

    private func recordItemVisit() {
        instrumentation.totalItemVisitCount += 1
        instrumentation.lastOperationItemVisitCount += 1
    }

    private func project(itemID: ItemID, input: Input) -> Presentation {
        instrumentation.totalProjectionCount += 1
        instrumentation.lastOperationProjectionCount += 1
        lastProjectedItemIDs.insert(itemID)
        return projector(
            itemID,
            input,
            SidebarAppKitProjectionContext(isHovered: hoveredItemID == itemID)
        )
    }

    private func finishOperation(diff: Diff) {
        instrumentation.lastOperationReloadCount = diff.reloadedItemIDs.count
        instrumentation.totalReloadCount += diff.reloadedItemIDs.count
    }
}
