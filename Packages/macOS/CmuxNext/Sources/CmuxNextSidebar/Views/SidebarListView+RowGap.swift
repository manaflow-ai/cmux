import AppKit

// One reorder rule for every row a drag passes (Lawrence 2026-11-15): the list's rows and a block's item rows
// (pinned workspaces) go through the same `SidebarDragGeometry.baseY` and `edgeY`. This file gives that rule the gap
// the drag shows open, wherever it is open.

/// The gap a row drag shows open: its top in the list and how far it moved what is under it.
struct SidebarRowGap {
    var y: CGFloat?
    var height: CGFloat
    /// A block's gap after its last item: the base y of a point in the gap. With the gap taken out, that point is
    /// the top of the list row under the block, and a drop "before that row" would leave the block (an unpin).
    var hold: CGFloat?

    /// Base `y`, kept in the block while the card is in its last gap or short of the middle of the row under the
    /// block: among list rows "before the row below" is the gap's own place, under a block it is another section.
    func held(_ y: CGFloat, in geometry: SidebarDragGeometry, x: CGFloat) -> CGFloat {
        guard let hold, let top = self.y, y >= top else { return y }
        guard y > top, let hit = geometry.hit(CGPoint(x: x, y: y)) else { return hold }
        let below = abs(hit.slot.frame.minY - top) < 0.5 && y < hit.slot.frame.midY && (hit.zone == .before || hit.slot.kind == .section)
        return below ? hold : y
    }
}

extension SidebarListViewComponents {
    /// The gap the drag shows open, as the row rule reads it (`SidebarDragGeometry.edgeY`, `baseY`): the list's own gap,
    /// or a block's gap among item rows (pinned workspaces), so pinned and unpinned rows reorder by one rule. Nil for
    /// a block's gap among tiles: they flow on lines, and the card's centre decides there (`baseY(displayY:blockGap:bases:)`).
    func rowGap(_ drag: SidebarListDrag) -> SidebarRowGap? {
        guard let gap = drag.blockTarget else { return SidebarRowGap(y: displayed.gapY, height: displayed.gapShift) }
        if drag.blockGapShape?.gap != gap {
            var rows: SidebarRowGap?
            if let row = displayed.row(for: .block(gap.section)), let base = drag.blockBases[gap.section],
               let content = blockContent(gap.section, includeGap: true) {
                let layout = SidebarRegionView.layout(of: content, width: bounds.width)
                for slot in layout.rows {
                    guard case let .item(id, _) = slot.kind, id == SidebarListBlocks.gapID else { continue }
                    // The block's items end above its bottom padding (the Chief's top section keeps a gap under it).
                    let y = row.y + slot.frame.minY, end = row.y + base.height - (content.metrics.bottomPadding ?? 0)
                    rows = SidebarRowGap(y: y, height: layout.height - base.height, hold: y >= end ? end - 1 : nil)
                }
            }
            drag.blockGapShape = (gap, rows)
        }
        return drag.blockGapShape?.rows
    }

    /// The base y a document drag's drop is hit-tested at, from the rest shape's centre `displayY`; nil keeps the
    /// drag's target (a turn back short of its hysteresis).
    func docDragBaseY(_ drag: SidebarListDrag, geometry: SidebarDragGeometry, rows: [String: SidebarRow], displayY: CGFloat, x: CGFloat, edges: Bool = true) -> CGFloat? {
        guard let gap = rowGap(drag) else { return baseY(displayY: displayY, blockGap: drag.blockTarget, bases: drag.blockBases) } // tiles: the centre
        var y = SidebarDragGeometry.baseY(displayY: displayY, gapY: gap.y, gapHeight: gap.height)
        if !edges { return gap.held(y, in: geometry, x: x) } // on the stuck header the centre alone decides
        // A row moves by its edges too (Lawrence 2026-10-20): its top past the middle of the row above moves it up,
        // its bottom past the middle of the row below moves it down (`SidebarDragGeometry.edgeY`). The rest shape's
        // edges, as for the centre, so a morph does not move them.
        let morphs = drag.morphs || drag.tileSource != nil
        let height = morphs ? drag.restFrame.height : drag.lift.frame.height
        let top = morphs ? displayY - height / 2 : drag.lift.frame.minY
        let reversing = drag.docTargetChangedUp.map { $0 != drag.movingUp } ?? false
        guard let edge = geometry.edgeY(top: top, bottom: top + height, x: x, movingUp: drag.movingUp, gapY: gap.y,
                                        gapHeight: gap.height, current: drag.docTarget, reversing: reversing) else { return nil }
        // Into a block from the list the centre decides, as before: half the card over the block's last row.
        if let hit = geometry.hit(CGPoint(x: x, y: edge)), rows[hit.slot.key] != nil || (drag.blockTarget != nil && hit.slot.kind == .row) { y = edge }
        return gap.held(y, in: geometry, x: x)
    }
}
