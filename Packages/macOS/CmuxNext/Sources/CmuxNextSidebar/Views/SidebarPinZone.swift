import AppKit

/// An empty Pinned's drop zone (its header and its "Drop here to pin" row) opens only where the drag goes: as the
/// pointer, moving up, reaches the top half of the list's first row (or above it), the zone opens there on the drag's
/// spring like any other gap, and it closes once the pointer leaves it by half a row. A drag's start moves no row
/// (Leo 2026-11-07: "it's super weird how when you drag ANY workspace, it shifts imediately due to that").
@MainActor enum SidebarPinZone {
    /// Opens or closes the zone for the pointer at `point` (list coordinates); a change shows at once, as a target
    /// change would, and the drag's base and document geometry are made again with the zone in or out.
    static func update(_ list: SidebarListView, _ drag: SidebarListDrag, at point: NSPoint) {
        guard let zone = drag.pinZone else { return }
        let half = list.metrics.rowHeight / 2
        let reaches = drag.reachesPinned ? point.y < zone.upperBound + half : drag.movingUp && point.y < zone.lowerBound + half
        guard reaches != drag.reachesPinned else { return }
        drag.reachesPinned = reaches
        drag.docGeometry = nil
        list.showDragLayout()
    }

    /// At the lift, after the drag's first look (`displayed`, the zone closed): where the zone opens, in the drag's
    /// base with it open. None when the drag takes no pin (a group), when Pinned lists rows, or when its zone shows
    /// already (the drag carries every pinned row: the zone holds their place). One layout per drag, none per move.
    static func begin(_ list: SidebarListView, _ drag: SidebarListDrag) {
        guard drag.group == nil, drag.docItems != nil || isWorkspaces(drag.payload), !list.displayed.rows.contains(where: { isZone($0.key) }) else { return }
        drag.reachesPinned = true
        let open = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: list.options(includeGap: false))
        drag.reachesPinned = false
        let rows = open.rows.filter { isZone($0.key) }
        guard let top = rows.map(\.y).min(), let bottom = rows.map(\.maxY).max() else { return }
        drag.pinZone = top...bottom
    }

    static func isZone(_ key: SidebarRowKey) -> Bool {
        switch key {
        case let .section(id), let .emptySection(id): id == .pinned || id == .custom(SidebarDocStore.pinnedSection)
        default: false
        }
    }

    private static func isWorkspaces(_ payload: DragPayload) -> Bool {
        if case .workspaces = payload { true } else { false }
    }
}
