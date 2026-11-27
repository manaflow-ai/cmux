import Foundation

/// The order a window's sidebar lists its workspaces in, top to bottom (group members in place, folded or not),
/// with each workspace's position and neighbours in O(1).
///
/// One order for every reader: tab search, `window list` and the window's membership order read it instead of
/// keeping their own copy that a move leaves stale. ``SidebarModel/workspaceOrder`` builds it once per structural
/// change of the rows (O(n)) and hands the same value to every query after that.
///
/// ```swift
/// let order = model.workspaceOrder
/// order.position(of: id)    // 0-based, nil when the window does not list it
/// order.neighbours(of: id)  // the rows above and below it
/// ```
public nonisolated struct SidebarWorkspaceOrder: Sendable, Equatable {
    /// The listed workspaces, top to bottom; a workspace listed twice (a saved row beside its live one) counts once,
    /// at its first place.
    public let ids: [WorkspaceID]
    private let positions: [WorkspaceID: Int]

    /// The order of the workspace rows in `sections`.
    ///
    /// - Parameter sections: A window's sidebar sections.
    public init(_ sections: [SidebarSection]) {
        var ids: [WorkspaceID] = []
        var positions: [WorkspaceID: Int] = [:]
        for workspace in sections.lazy.flatMap(\.workspaces) where positions[workspace.id] == nil {
            positions[workspace.id] = ids.count
            ids.append(workspace.id)
        }
        self.ids = ids
        self.positions = positions
    }

    /// Where `id` lists, counted from 0 at the top; nil when the window does not list it.
    ///
    /// - Parameter id: A workspace.
    /// - Returns: Its position, in O(1).
    public func position(of id: WorkspaceID) -> Int? { positions[id] }

    /// `members` with the ones this order lists put in its order, each in a slot a listed member held; a member it
    /// does not list (another room's, one not drawn yet) keeps its slot. A window's membership changes only when a
    /// workspace joins or leaves it: this is the order `window list` and Search Tabs show after a move.
    ///
    /// - Parameter members: Workspace ids (`WorkspaceID.rawValue`), in membership order.
    /// - Returns: The same ids, the listed ones in sidebar order.
    public func ordering(_ members: [String]) -> [String] {
        var slots: [Int] = []
        var listed: [(position: Int, id: String)] = []
        for (slot, id) in members.enumerated() {
            guard let position = positions[WorkspaceID(id)] else { continue }
            slots.append(slot)
            listed.append((position, id))
        }
        guard !listed.isEmpty else { return members }
        listed.sort { $0.position < $1.position }
        var ordered = members
        for (slot, entry) in zip(slots, listed) { ordered[slot] = entry.id }
        return ordered
    }

    /// The workspaces listed right above and right below `id` (nil at an end); nil when the window does not list it.
    ///
    /// - Parameter id: A workspace.
    /// - Returns: Its neighbours, in O(1).
    public func neighbours(of id: WorkspaceID) -> (above: WorkspaceID?, below: WorkspaceID?)? {
        guard let at = positions[id] else { return nil }
        return (at > 0 ? ids[at - 1] : nil, at + 1 < ids.count ? ids[at + 1] : nil)
    }
}
