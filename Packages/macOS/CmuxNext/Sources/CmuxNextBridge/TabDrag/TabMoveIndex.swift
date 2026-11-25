internal import CCmuxLayoutReducerFFI

/// Index conversions for the daemon's `move-tab`.
public nonisolated enum TabMoveIndex {
    /// The wire index for moving a tab to `finalIndex` (its position after
    /// the move). `move-tab` takes insertion coordinates in the pre-move
    /// list: for a same-pane move the daemon removes the tab first and
    /// subtracts one from an index past it (cmux-tui spec "move-tab").
    /// `currentIndex` is the tab's index when it is already in the
    /// destination pane, else nil (cross-pane moves use the final index).
    public static func wireIndex(finalIndex: Int, currentIndex: Int?) -> Int {
        Int(cmux_tab_move_wire_index(Int64(finalIndex), currentIndex == nil ? 0 : 1, Int64(currentIndex ?? 0)))
    }

    /// The final index in the pane's own (daemon) order for a strip drop
    /// that puts `moving` at `displayIndex` of the strip's display order.
    /// The strip shows pinned tabs first, group members together, closing
    /// tabs hidden and app-local tabs last, so a display index is not a
    /// pane index. The tab goes right before the pane tab that follows it
    /// in the new display order, else last.
    public static func paneFinalIndex(display: [String], moving: String, displayIndex: Int, pane: [String]) -> Int {
        var interner = StringInterner()
        let movingID = interner.id(for: moving)
        let displayIDs = display.map { interner.id(for: $0) }
        let paneIDs = pane.map { interner.id(for: $0) }
        return displayIDs.withUnsafeBufferPointer { displayBuffer in
            paneIDs.withUnsafeBufferPointer { paneBuffer in
                Int(cmux_tab_move_pane_final_index(
                    displayBuffer.baseAddress, displayBuffer.count, movingID, Int64(displayIndex),
                    paneBuffer.baseAddress, paneBuffer.count
                ))
            }
        }
    }

    /// The position inside `group` for a strip drop that puts `moving` at
    /// `displayIndex` of the strip's display order: the members of `group`
    /// shown before it. `add-tabs-to-group` takes a position inside the
    /// group, the strip reports a display index.
    public static func groupIndex(display: [String], members: Set<String>, moving: String, displayIndex: Int) -> Int {
        var interner = StringInterner()
        let movingID = interner.id(for: moving)
        let displayIDs = display.map { interner.id(for: $0) }
        let memberIDs = members.map { interner.id(for: $0) }
        return displayIDs.withUnsafeBufferPointer { displayBuffer in
            memberIDs.withUnsafeBufferPointer { memberBuffer in
                Int(cmux_tab_move_group_index(
                    displayBuffer.baseAddress, displayBuffer.count, memberBuffer.baseAddress, memberBuffer.count,
                    movingID, Int64(displayIndex)
                ))
            }
        }
    }

    /// Call-local transport IDs preserve Swift String equality, including canonical
    /// Unicode equivalence and embedded NULs. No string bytes cross the ABI.
    private nonisolated struct StringInterner {
        private var ids: [String: UInt32] = [:]

        mutating func id(for value: String) -> UInt32 {
            if let existing = ids[value] { return existing }
            // An exact conversion prevents distinct strings ever sharing an ID.
            let next = UInt32(ids.count)
            ids[value] = next
            return next
        }
    }
}
