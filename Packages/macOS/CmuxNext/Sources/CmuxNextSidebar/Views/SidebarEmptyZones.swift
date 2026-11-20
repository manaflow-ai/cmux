import AppKit

/// An empty section's drop zone (a "Drop here to pin" row, or an empty list's blank row) opens only where the drag goes,
/// never at its start (Leo 2026-11-07: "it's super weird how when you drag ANY workspace, it shifts imediately due to
/// that"). Pinned's opens as the pointer, moving up, reaches the top half of the row it opens above (or above it); a
/// titled section's as the pointer reaches its title. One zone opens at a time, on the drag's spring like any gap, and
/// closes once the pointer leaves it by half a row.
@MainActor enum SidebarEmptyZones {
    /// One zone the drag can open, in the list's coordinates with every zone shut.
    struct Zone {
        /// The document section (`SidebarDocStore.pinnedSection` for Pinned, on the document or not).
        var id: String
        /// Where the pointer starts to reach it (nil: anywhere above, moving up) and where it opens.
        var top: CGFloat?
        var at: CGFloat
        /// What it adds when open, and half the row under it (the reach past `at`).
        var height: CGFloat
        var half: CGFloat
        /// A row that moves with the zone (its title's block, or the row it opens above) and that row's y at the lift:
        /// a drop's gap that moves the row moves the zone by as much.
        var anchor: SidebarRowKey?
        var anchorY: CGFloat = 0

        /// The zone where it is now: moved as its anchor moved since the lift, less what the open zone `open` adds above
        /// the anchor.
        func placed(in list: SidebarListView, open: Zone?) -> Zone {
            guard let anchor, let now = list.displayed.row(for: anchor)?.y else { return self }
            var shift = now - anchorY
            if let open, open.at <= anchorY + 0.5 { shift -= open.height }
            guard abs(shift) > 0.5 else { return self }
            var zone = self
            zone.top = top.map { $0 + shift }
            zone.at += shift
            return zone
        }
    }

    /// Opens or closes a zone for the pointer at `point` (list coordinates). A change shows at once, as a target
    /// change would; the drag's base, document geometry and group plan are made again with the zone in or out.
    static func update(_ list: SidebarListView, _ drag: SidebarListDrag, at point: NSPoint) {
        guard !drag.zones.isEmpty else { return }
        var y = point.y
        let lifted = drag.openZone.flatMap { id in drag.zones.first { $0.id == id } }
        let zones = drag.zones.map { $0.placed(in: list, open: lifted) }
        let open = drag.openZone.flatMap { id in zones.first { $0.id == id } }
        if let open {
            if y >= (open.top ?? -.infinity), y < open.at + open.height + open.half { return }
            if y > open.at { y -= open.height } // back to the shut list's coordinates
        }
        let reached = zones.first { zone in
            y < zone.at + zone.half && (zone.top.map { y >= $0 } ?? drag.movingUp)
        }
        guard reached?.id != drag.openZone else { return }
        drag.openZone = reached?.id
        drag.docGeometry = nil
        if let top = drag.group?.plan.groupTop {
            // The group's own place, shut, then with the new zone: a zone above it moves it down by the zone's height.
            let shut = top - (open.map { $0.at < top ? $0.height : 0 } ?? 0)
            let moved = shut + (reached.map { $0.at < shut ? $0.height : 0 } ?? 0)
            list.rebaseGroupDrag(drag, shift: moved - top)
        }
        list.showDragLayout()
    }

    /// At the lift, before the drag's first look (the rest layout still shows Pinned): a list Pinned the drag empties
    /// keeps its header and drop row for the whole drag (`keepsPinned`), so its rows can go back.
    static func keepPinned(_ list: SidebarListView, _ drag: SidebarListDrag) {
        guard list.displayed.rows.contains(where: { $0.key == .section(.pinned) || $0.key == .emptySection(.pinned) }) else { return }
        let nodes = list.model.sections.first { $0.id == .pinned }?.nodes ?? []
        if nodes.allSatisfy({ if case let .workspace(ws) = $0 { drag.hiddenKeys.contains(.workspace(ws.id)) } else { false } }) {
            drag.keepsPinned = true
        }
    }

    /// At the lift, after the drag's first look (`displayed`, every zone shut): the zones it can open. A list Pinned
    /// the drag empties keeps its header and zone for the whole drag instead (`keepsPinned`), so the drag can go back.
    /// One layout per drag (for an untitled Pinned), none per move.
    static func begin(_ list: SidebarListView, _ drag: SidebarListDrag) {
        // A drag the document does not take (a workspace it places nowhere yet) resolves on the list, which drops into
        // no document section: it opens none of theirs.
        let onDocument = drag.docItems != nil
        guard onDocument || (list.model.docDrag == nil && isWorkspaces(drag.payload)) else { return }
        if !onDocument && drag.group != nil { return }
        var zones: [Zone] = []
        let shown = list.displayed.rows.filter { !drag.hiddenKeys.contains($0.key) }
        let height = list.metrics.emptySectionHeight + list.displayed.rowSpacing
        if let blocks = list.blocks, onDocument {
            // A collapsed one too: its title is all it draws, and the drag still drops into it.
            for (id, section) in blocks.sections where section.items.isEmpty && takes(drag, id) {
                guard let block = shown.first(where: { $0.key == .block(id) }), block.height > 0,
                      !shown.contains(where: { $0.key == .emptySection(.custom(id)) }) else { continue }
                let under = shown.first { $0.y >= block.maxY - 0.5 && $0.key != block.key }
                zones.append(Zone(id: id, top: block.y, at: block.maxY, height: height, half: (under?.height ?? list.metrics.rowHeight) / 2,
                                  anchor: block.key, anchorY: block.y))
            }
        }
        let pinnedItems = list.blocks?.sections[SidebarDocStore.pinnedSection]?.items ?? []
        if !zones.contains(where: { $0.id == SidebarDocStore.pinnedSection }), !drag.keepsPinned, takes(drag, SidebarDocStore.pinnedSection),
           pinnedItems.allSatisfy({ drag.docItems?.contains($0.id.rawValue) == true }),
           !list.displayed.rows.contains(where: { isPinnedZone($0.key) }) {
            drag.openZone = SidebarDocStore.pinnedSection
            let open = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: list.options(includeGap: false))
            drag.openZone = nil
            let rows = open.rows.filter { isPinnedZone($0.key) }
            if let top = rows.map(\.y).min(), let bottom = rows.map(\.maxY).max() {
                // The row the zone opens above, at its own height (density, a status or detail line).
                let under = shown.first { $0.y >= top - 0.5 }
                zones.append(Zone(id: SidebarDocStore.pinnedSection, top: nil, at: top, height: bottom - top + list.displayed.rowSpacing,
                                  half: (under?.height ?? list.metrics.rowHeight) / 2, anchor: under?.key, anchorY: under?.y ?? 0))
            }
        }
        drag.zones = zones.sorted { $0.at < $1.at }
    }

    /// Pinned's header or its drop row, on the list or on the document.
    static func isPinnedZone(_ key: SidebarRowKey) -> Bool {
        switch key {
        case let .section(id), let .emptySection(id): id == .pinned || id == .custom(SidebarDocStore.pinnedSection)
        default: false
        }
    }

    /// The document takes the drag into section `id` (a section the table lacks takes it, as its slot does). Pinned
    /// refuses an item from outside it (`keepingPinned`: Pin is the way in), so it opens no zone for one.
    private static func takes(_ drag: SidebarListDrag, _ id: String) -> Bool {
        drag.docItems == nil || drag.docAcceptance.isEmpty || (drag.docAcceptance[id]?.into ?? true)
    }

    private static func isWorkspaces(_ payload: DragPayload) -> Bool {
        if case .workspaces = payload { true } else { false }
    }
}
