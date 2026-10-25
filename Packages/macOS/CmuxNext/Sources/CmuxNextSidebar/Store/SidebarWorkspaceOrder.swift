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

    /// The workspaces listed right above and right below `id` (nil at an end); nil when the window does not list it.
    ///
    /// - Parameter id: A workspace.
    /// - Returns: Its neighbours, in O(1).
    public func neighbours(of id: WorkspaceID) -> (above: WorkspaceID?, below: WorkspaceID?)? {
        guard let at = positions[id] else { return nil }
        return (at > 0 ? ids[at - 1] : nil, at + 1 < ids.count ? ids[at + 1] : nil)
    }
}
