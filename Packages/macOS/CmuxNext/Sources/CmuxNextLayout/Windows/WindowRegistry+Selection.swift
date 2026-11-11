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
    ///   old order, then the first member, by the one close-selection rule (`rule`'s openers;
    ///   `WindowCloseSelection.pick`, close-focus.md); only then is `orders`
    ///   read, a walk of every row, which most changes skip. `batch`: a person's close
    ///   of several rows, by position with no opener rank (`WindowCloseSelection.pick`),
    /// - no members: nil (only for a window being removed; a registered
    ///   window always has one).
    public static func repairedSelection(current: String?, previous: [String], members: [String], preferred: [String] = [], orders: @autoclosure () -> [[String]] = [],
                                         rule: WindowCloseSelection, batch: Bool = false) -> String? {
        if let pick = preferred.first(where: members.contains) ?? current.flatMap({ members.contains($0) ? $0 : nil }) { return pick }
        return rule.pick(shown: current, previous: previous, members: members, orders: orders(), batch: batch)
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
    /// run's scope cannot say whose selection it is. `batch`: the person closed several rows in
    /// one gesture; the pick is by position (`WindowCloseSelection.pick`).
    public func repairSelection(of window: String, shown: String?, previous: [String], members: [String], preferred: [String] = [], gesture: Bool, batch: Bool = false,
                                claimed: (String) -> Bool = { _ in false }, orders: @autoclosure () -> [[String]] = [], select: (String?) -> Void) {
        let pick = WindowRegistry.repairedSelection(current: shown, previous: previous, members: members, preferred: preferred, orders: orders(), rule: closeSelection, batch: batch)
        // The selection a close or a delta causes is no gesture of the person; a workspace they just moved in is theirs.
        if shown != pick { closeSelection.repairing(!(gesture && pick.map(preferred.contains) == true)) { select(pick) } }
        // After the pick: a workspace no window lists any more (its close is committed) or that moved ends its relations.
        closeSelection.settle(window, owner: { value.owner(of: $0) }, exists: { value.window($0) != nil }, claimed: claimed)
    }
}
