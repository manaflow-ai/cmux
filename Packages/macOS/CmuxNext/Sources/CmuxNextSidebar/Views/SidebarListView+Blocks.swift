import AppKit
import CmuxNextDesign

// The sidebar document's one section renderer (sidebar-v2): the list draws
// every section in document order. A machine section's rows, and the groups
// of Pinned and custom sections, are list rows; the other items of Pinned,
// custom and app sections draw in their section's own arrangement (tiles, a
// grid, one line, item rows) in one block row (`SidebarRowKey.block`) whose
// region is the band's drawing, so tiles and rows look as before. One drag
// serves them all: a row or a tile lifts, `SidebarDragGeometry` hit-tests
// the list rows and the block items with the drag's one `drag_begin` table,
// and the drop opens a gap where it goes (the list's gap, or a tile slot
// that the block's items make way for, animated as the list's rows) or
// highlights the group header it goes into.

/// Where a drag opens a gap in a block: its section and the index among its items.
struct SidebarBlockGap: Hashable {
    var section: String
    var index: Int
}

/// A dropped drag kept on screen until its move lands (`SidebarListView.settling`).
struct SidebarSettlingDrop {
    let drag: SidebarListDrag
    /// The drop's change (`SidebarDocStore.lastIntentKey`): its refusal or no-op ends the settle.
    var key: String?
    /// The list's structure and the blocks when the drop was sent: either changing ends the settle.
    var revision: UInt64
    var blocks: SidebarListBlocks?
    /// The card reached its slot before the model showed the drop: it holds the slot until then.
    var landed = false
    /// What the card's landing runs once it is done.
    var then: (@MainActor () -> Void)?
}

/// What the blocks draw: the shown sections of the document (the ones before
/// the machine lists, presented as the band presented them) and the band's
/// drawing inputs.
struct SidebarListBlocks: Equatable {
    /// The transient item a gap holds: drawn invisible, it makes the block's items make way.
    static let gapID = LayoutItemID(LayoutItemID.transientPrefix + "sidebar-gap")

    var sections: [String: LayoutSection]
    var infos: [LayoutItemID: SidebarItemInfo]
    var collapsed: Set<LayoutSectionID>
    var look: SectionsLookVariant
    var metrics: SidebarRegionMetrics
    var drawsLines: Bool
    var appHeights: [LayoutSectionID: CGFloat]

    /// Section `id` without `hiding` and with a gap at `gap` (an index among the items left), as wide as the first hidden item.
    /// `joinsAbove`: a block drawn right before it, so the two keep one band's spacing (a section gap and its line between
    /// them, the band's padding only at the run's top). A block has no bottom padding in the list: the list puts its row
    /// spacing (or the next block's top edge) under the last item, so the rows under the pins follow as rows follow
    /// rows (Leo 2026-10-21).
    func content(_ id: String, hiding: Set<String>, gap: Int?, joinsAbove: Bool = false) -> SidebarRegionView.Content? {
        guard var section = sections[id] else { return nil }
        section.items.removeAll { hiding.contains($0.id.rawValue) }
        var infos = infos
        if let gap {
            let moving = sections.values.lazy.flatMap(\.items).first { hiding.contains($0.id.rawValue) }
            let slot = LayoutItem(id: Self.gapID, ref: moving?.ref ?? .builtIn(.home), showsLabel: moving?.showsLabel ?? true, span: moving?.span,
                                  label: moving?.label)
            if let moving { infos[Self.gapID] = infos[moving.id] }
            section.items.insert(slot, at: min(max(0, gap), section.items.count))
        }
        var edges = metrics
        if joinsAbove { (edges.topPadding, edges.leadingSeparator) = (metrics.sectionGap, true) }
        edges.bottomPadding = 0
        return SidebarRegionView.Content(sections: [section], infos: infos, collapsed: collapsed, look: look, metrics: edges,
                                         drawsLines: drawsLines, appHeights: appHeights)
    }
}

/// One block row: a region that draws one document section. Its tiles and
/// rows take their own clicks, menus and drags (the drags are the list's).
final class SidebarBlockRowView: SidebarRowView {
    let region = SidebarRegionView(region: .top)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.cornerRadius = 0
        addSubview(region)
    }

    /// The region's own views take the pointer (tiles, the header, an app section).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return region.hitTest(convert(local, to: region.superview))
    }

    /// Shows `content` on the drag's one spring (items, cards, lines; `SidebarRegionView.springShow`).
    func springShow(_ content: SidebarRegionView.Content, width: CGFloat) {
        region.springShow(content, width: width)
        region.frame = NSRect(x: 0, y: 0, width: width, height: region.layoutResult.height)
    }

    func show(_ content: SidebarRegionView.Content, width: CGFloat, animated: Bool) {
        region.show(content, width: width, animated: animated)
        region.frame = NSRect(x: 0, y: 0, width: width, height: region.layoutResult.height)
    }

    override func updateLayer() {}

    override func layout() {
        super.layout()
        // The list resizes this row on a sidebar resize without configuring it again.
        region.fit(width: layoutBounds.width)
        region.frame = NSRect(x: 0, y: 0, width: layoutBounds.width, height: region.layoutResult.height)
    }
}

extension SidebarListViewComponents {
    /// The items the drag lifts (or a held drop moved), which no block draws meanwhile.
    private var blockHidden: Set<String> {
        Set(shownDrag?.docItems ?? [])
    }

    /// Block `id`'s content as drawn (with the drag's or the held drop's gap) or as the hit test's base (without it).
    func blockContent(_ id: String, includeGap: Bool) -> SidebarRegionView.Content? {
        let gap = includeGap ? shownDrag?.blockTarget.flatMap { $0.section == id ? $0.index : nil } : nil
        return blocks?.content(id, hiding: blockHidden, gap: gap, joinsAbove: joinsBlockAbove(id))
    }

    /// Whether block `id` has another block right above it in the list (no rows between them), by the
    /// layout's own rules: a collapsed section or one whose groups the filter or the drag leave out lists no rows,
    /// and a section whose items lay out to nothing draws no block.
    func joinsBlockAbove(_ id: String) -> Bool {
        let sections = model.sections
        guard let index = sections.firstIndex(where: { $0.id == .custom(id) }) else { return false }
        let matches = model.filterMatches
        var excludedGroup: GroupID?
        if case let .group(group)? = shownDrag?.payload { excludedGroup = group }
        func docID(_ section: SidebarSection) -> String? {
            if case let .custom(custom) = section.kind { custom.id } else { nil }
        }
        func listsNoRows(_ section: SidebarSection) -> Bool {
            guard let id = docID(section) else { return false }
            if model.collapsedLayoutSections.contains(LayoutSectionID(id)) { return true }
            return !section.nodes.contains { node in
                guard case let .group(group) = node, group.id != excludedGroup else { return false }
                return matches.map { matches in group.workspaces.contains { matches.contains($0.id) } } ?? true
            }
        }
        func hasBlock(_ section: SidebarSection) -> Bool {
            guard let id = docID(section), let content = blocks?.content(id, hiding: blockHidden, gap: nil) else { return false }
            return SidebarRegionView.layout(of: content, width: bounds.width).height > 0
        }
        return index > 0 && listsNoRows(sections[index - 1]) && hasBlock(sections[index - 1])
    }

    /// Ends a settling drop once its move landed (the list's structure or the blocks changed); returns it.
    func settleDrop() -> SidebarSettlingDrop? {
        guard let held = settling, model.sectionsRevision != held.revision || blocks != held.blocks else { return nil }
        settling = nil
        return held
    }

    /// The gap's frame in the list (where a dropped card lands).
    func blockGapFrame(_ gap: SidebarBlockGap) -> NSRect? {
        guard let row = displayed.row(for: .block(gap.section)), let block = rowViews[row.key] as? SidebarBlockRowView,
              let slot = block.region.itemView(SidebarListBlocks.gapID) else { return nil }
        return convert(slot.bounds, from: slot)
    }

    /// The gap slot's frame in the list as the block lays it out with the gap
    /// (its final frame, not its animated one): the shape a card morphs to.
    func blockSlotFrame(_ gap: SidebarBlockGap) -> NSRect? {
        guard let row = displayed.row(for: .block(gap.section)), let content = blockContent(gap.section, includeGap: true) else { return nil }
        let layout = SidebarRegionView.layout(of: content, width: bounds.width)
        let slot = layout.rows.first { row in
            switch row.kind {
            case let .tile(id, _), let .chip(id, _), let .item(id, _): id == SidebarListBlocks.gapID
            default: false
            }
        }
        return slot.map { $0.frame.offsetBy(dx: 0, dy: row.y) }
    }

    /// Each block's height at the list's width.
    func blockHeights(includeGap: Bool) -> [String: CGFloat] {
        guard let blocks else { return [:] }
        var heights: [String: CGFloat] = [:]
        for id in blocks.sections.keys {
            guard let content = blockContent(id, includeGap: includeGap) else { continue }
            heights[id] = SidebarRegionView.layout(of: content, width: bounds.width).height
        }
        return heights
    }

    /// The blocks' regions now in the list (debug frames, the hover walk).
    var blockRegions: [SidebarRegionView] {
        rowViews.values.compactMap { ($0 as? SidebarBlockRowView)?.region }
    }

    /// A press on item `id` of block `section` moved: past the threshold the
    /// list's one drag lifts it (the tile's snapshot follows the pointer).
    func dragTile(_ id: LayoutItemID, section: String, in region: SidebarRegionView, from start: NSPoint, _ event: NSEvent) -> Bool {
        if drag == nil {
            abandonSettle()
            guard let doc = model.docDrag, !model.locksReorder, let view = region.itemView(id) else { return false }
            let origin = convert(start, from: nil), point = convert(event.locationInWindow, from: nil)
            guard SidebarPress.movedPastThreshold(from: origin, to: point) else { return false }
            endLanding()
            hoverCards.dismiss(.click)
            let frame = convert(view.bounds, from: view)
            let card = NSImageView()
            card.imageScaling = .scaleNone
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = NSImage(size: view.bounds.size)
                image.addRepresentation(rep)
                card.image = image
            }
            let lift = SidebarReorderLift.lift(card, frame: frame, in: self)
            let drag = Drag(payload: .item(id.rawValue), grabbedKey: .item(id.rawValue), hiddenKeys: [], grabOffsetY: origin.y - frame.minY,
                            gapHeight: metrics.rowHeight, lift: lift, target: nil)
            drag.grabOffsetX = origin.x - frame.minX
            drag.lastY = origin.y
            drag.tileSource = (section, id)
            drag.restFrame = NSRect(x: inset, y: frame.minY, width: max(0, bounds.width - inset * 2), height: metrics.rowHeight)
            drag.restShaped = false
            drag.tileRegion = region
            region.docPressedItem = id
            drag.docItems = [id.rawValue]
            drag.docAcceptance = doc.begin([id.rawValue])
            self.drag = drag
            setHovered(nil)
            showDragLayout() // the tile's slot closes on the drag's spring
        }
        updateDrag(windowPoint: event.locationInWindow)
        return true
    }

    /// The base layout of every block for a drag's hit test (its items without the dragged ones).
    func blockBases() -> [String: SidebarRegionLayout] {
        guard let blocks else { return [:] }
        var bases: [String: SidebarRegionLayout] = [:]
        for id in blocks.sections.keys {
            if let content = blockContent(id, includeGap: false) { bases[id] = SidebarRegionView.layout(of: content, width: bounds.width) }
        }
        return bases
    }

    /// The base y of a display y while a block's gap is open: rows below the
    /// block were pushed down by the gap; a point in the gap's part of the
    /// block hits the block's last base line.
    func baseY(displayY y: CGFloat, blockGap: SidebarBlockGap?, bases: [String: SidebarRegionLayout]) -> CGFloat {
        guard let gap = blockGap, let row = displayed.row(for: .block(gap.section)), let base = bases[gap.section]?.height else { return y }
        if y >= row.maxY { return y - (row.height - base) }
        return y >= row.y + base ? row.y + base - 1 : y
    }

    /// The index among section `id`'s items (without the moved ones) where `target` puts them.
    func blockIndex(_ target: SidebarDocTarget, section id: String, moving: [String]) -> Int {
        let items = (blocks?.sections[id]?.items ?? []).map(\.id.rawValue).filter { !moving.contains($0) }
        if let before = target.before, let index = items.firstIndex(of: before) { return index }
        if let after = target.after, let index = items.firstIndex(of: after) { return index + 1 }
        return min(max(0, target.index ?? 0), items.count)
    }
}

extension SidebarListViewComponents {
    /// Where a dropped card settles: the block's gap, the list's gap (a tile
    /// dropped among rows), else its own rows at the slot (nil: `land` finds them).
    func settleFrame(_ drag: SidebarListDrag) -> NSRect? {
        // A group lands at its cut height in its slot; it grows to the whole group when the model shows it.
        if let frame = groupSlotFrame(drag) { return frame }
        if let gap = drag.blockTarget {
            // A card that keeps its own shape over a block (a group, a workspace with tab rows) is not a tile: the
            // model draws it as rows, not in the slot. It holds where it is until the model shows it (no flight
            // toward a tile's shape and back; ptr8 group-into-pinned).
            guard drag.morphs || drag.tileSource != nil else { return drag.lift.frame }
            return blockSlotFrame(gap) ?? blockGapFrame(gap)
        }
        if drag.tileSource != nil, let y = displayed.gapY, displayed.gapHeight > 0 {
            return NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: displayed.gapHeight)
        }
        return nil
    }
}
