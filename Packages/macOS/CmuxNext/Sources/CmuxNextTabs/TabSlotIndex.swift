import Foundation

/// Where each tab sits in one ``TabLayoutResult``: its slot, and its place in the row of drawn tabs
/// (collapsed group members are out of the row). Built once per layout, so a tab switch finds the
/// two tabs it changes in O(1) instead of walking every slot (tab-switch-rewrite).
struct TabSlotIndex {
    /// Every slot by tab id.
    let slots: [TabID: TabLayoutSlot]
    /// The drawn row, left to right.
    let row: [TabID]
    /// Each drawn tab's place in ``row``.
    let rowIndex: [TabID: Int]

    init(_ result: TabLayoutResult) {
        var slots: [TabID: TabLayoutSlot] = [:]
        var row: [TabID] = []
        var rowIndex: [TabID: Int] = [:]
        slots.reserveCapacity(result.slots.count)
        for slot in result.slots {
            // Duplicate ids (bad model data) keep the first, as `TabLayoutResult.slot(_:)` does.
            if slots[slot.id] == nil { slots[slot.id] = slot }
            guard !slot.isCollapsed, rowIndex[slot.id] == nil else { continue }
            rowIndex[slot.id] = row.count
            row.append(slot.id)
        }
        self.slots = slots
        self.row = row
        self.rowIndex = rowIndex
    }
}
