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
    ///   `WindowCloseSelection.pick`, close-focus.md). No `rule`: by position;
    ///   only then is `orders` read, a walk of every row, which most changes skip,
    /// - no members: nil (only for a window being removed; a registered
    ///   window always has one).
    public static func repairedSelection(current: String?, previous: [String], members: [String], preferred: [String] = [], orders: @autoclosure () -> [[String]] = [],
                                         rule: WindowCloseSelection? = nil) -> String? {
        if let pick = preferred.first(where: members.contains) ?? current.flatMap({ members.contains($0) ? $0 : nil }) { return pick }
        return (rule ?? WindowCloseSelection()).pick(shown: current, previous: previous, members: members, orders: orders())
    }
}

extension WindowRegistryStore {
    /// Repairs the selection of `window` after its rows changed from `previous` to `members`, for
    /// every close entry point: the pick (`WindowRegistry.repairedSelection` with this store's
    /// close-selection state), `select` when the window must show another workspace, then the
    /// state settles. `shown` is what the window shows now. "The next row" is the sidebar's next
    /// drawn row, not the next member to have joined: `orders` gives the rows as drawn, then the
    /// model's. `claimed`: the workspace is a create its window waits for.
    public func repairSelection(of window: String, shown: String?, previous: [String], members: [String], preferred: [String] = [],
                                claimed: (String) -> Bool = { _ in false }, orders: @autoclosure () -> [[String]] = [], select: (String?) -> Void) {
        let pick = WindowRegistry.repairedSelection(current: shown, previous: previous, members: members, preferred: preferred, orders: orders(), rule: closeSelection)
        // The selection a close causes is no gesture of the person; a workspace they just moved in or made is theirs.
        if shown != pick { closeSelection.repairing(pick.map { preferred.contains($0) } != true) { select(pick) } }
        // After the pick: a closed or moved workspace ends its relations.
        closeSelection.settle(window, previous: previous, members: members, owner: { value.owner(of: $0) }, exists: { value.window($0) != nil }, claimed: claimed)
    }
}
