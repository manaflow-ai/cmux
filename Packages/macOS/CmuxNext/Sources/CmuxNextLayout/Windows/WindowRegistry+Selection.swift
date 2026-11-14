import CmuxNextDesign
import Foundation

extension WindowRegistry {
    /// The workspace a window should show after its membership changed from
    /// `previous` to `members`. The selection belongs to the window's
    /// `WindowState`; this only repairs it:
    /// - `preferred` (workspaces just moved in by the user) wins,
    /// - a selection that is still a member stays,
    /// - a selection that left falls to its next surviving neighbor in the
    ///   sidebar's row `orders` (the drawn rows, then the model's), then the
    ///   old order, then the first member, by the one close-selection rule (Rust's pick through
    ///   `WindowCloseSelection.pick`, close-focus.md); only then is `orders`
    ///   read, a walk of every row, which most changes skip. A close of several rows is the
    ///   same pick: `members` holds the survivors,
    /// - no members: nil (only for a window being removed; a registered
    ///   window always has one).
    public static func repairedSelection(current: String?, previous: [String], members: [String], preferred: [String] = [], orders: @autoclosure () -> [[String]] = [],
                                         rule: WindowCloseSelection) -> String? {
        // Kept in Swift, as before the rule: most changes end here with no call and no id numbered (Rust's twin is `cmux_window_close_selection_kept`).
        if let pick = preferred.first(where: members.contains) ?? current.flatMap({ members.contains($0) ? $0 : nil }) { return pick }
        return rule.pick(shown: current, previous: previous, members: members, orders: orders())
    }
}

extension WindowRegistryStore {
    /// Repairs the selection of `window` after its rows changed from `previous` to `members`, for
    /// every close entry point: the pick (`WindowRegistry.repairedSelection` with this store's
    /// close-selection state), `select` when the window must show another workspace, then the
    /// state settles. `shown` is what the window shows now. "The next row" is the sidebar's next
    /// drawn row, not the next member to have joined: `orders` gives the rows as drawn, then the
    /// model's. `claimed`: the workspace is a create its window waits for. `gesture`: the caller
    /// says that a person asked, in this turn, for the selection of a `preferred` workspace (a
    /// move in, a drop). A daemon delta's caller says false: no action run surrounds it, so the
    /// run's scope cannot say whose selection it is. `pressed`: the repair runs at the press of a
    /// close that hid rows and that can still be cancelled or refused (`WindowCloseSelection.repair`).
    public func repairSelection(of window: String, shown: String?, previous: [String], members: [String], preferred: [String] = [], gesture: Bool, pressed: Bool = false,
                                claimed: (String) -> Bool = { _ in false }, orders: @autoclosure () -> [[String]] = [], select: (String?) -> Void) {
        let pick = WindowRegistry.repairedSelection(current: shown, previous: previous, members: members, preferred: preferred, orders: orders(), rule: closeSelection)
        // Rust says whose selection it is: a close's or a delta's is no gesture of the person; a workspace they just moved in is theirs.
        if shown != pick { closeSelection.repair(shown: shown, pick: pick, gesture: gesture, pressed: pressed, members: members, preferred: preferred) { select(pick) } }
        // After the pick: a workspace no window lists any more (its close is committed) or that moved ends its relations.
        closeSelection.settle(window, owner: { value.owner(of: $0) }, exists: { value.window($0) != nil }, claimed: claimed)
    }
}
