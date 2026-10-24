import Foundation

/// The last `SidebarDocStore.projection(live:)` and what it was built over.
///
/// The reducer's view depends on the document (`version`), on which workspaces are live, and on the order of the live
/// workspaces the document does not place (they list in live order). The order of placed workspaces does not reach it:
/// the document orders them. So a daemon reorder of placed workspaces (`workspace move`, a store snapshot laid over
/// again) reuses the projection: no reducer view call and no rebuild of every row (sidebar-churn-typing.py).
nonisolated struct SidebarDocProjectionCache {
    let version: UInt64
    /// The live list it was built over, as given (`showsPinned` projects over it again).
    let live: [SidebarDocWorkspaceRef]
    let liveSet: Set<SidebarDocWorkspaceRef>
    /// The live workspaces it does not place, in live order.
    let unplacedOrder: [SidebarDocWorkspaceRef]
    let projection: SidebarDocProjection

    init(version: UInt64, live: [SidebarDocWorkspaceRef], projection: SidebarDocProjection) {
        self.version = version
        self.live = live
        liveSet = Set(live)
        unplacedOrder = Self.unplaced(live, in: projection)
        self.projection = projection
    }

    /// Whether `live` at `version` projects to `projection`: same document, same live set, same order of the
    /// workspaces it does not place. A ref without an item here is either unplaced or placed out of view; both keep
    /// their order in the key, so a reuse is never wrong (at worst a rebuild is not skipped).
    func answers(version: UInt64, live: [SidebarDocWorkspaceRef]) -> Bool {
        guard version == self.version, live.count == self.live.count else { return false }
        if live == self.live { return true }
        return Set(live) == liveSet && Self.unplaced(live, in: projection) == unplacedOrder
    }

    private static func unplaced(_ live: [SidebarDocWorkspaceRef], in projection: SidebarDocProjection) -> [SidebarDocWorkspaceRef] {
        live.filter { projection.items[$0] == nil }
    }
}
