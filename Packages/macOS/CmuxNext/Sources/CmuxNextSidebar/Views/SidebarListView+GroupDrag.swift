import AppKit

// A held group drag (plans/cmux-next/sidebar-owner.md, "Group drag: design for the rewrite"; Lawrence 2026-10-23).
// At lift the list without the group is laid out once (the base) and cut into top-level blocks; the card is cut to
// its header and three rows; each slot's drop is worked out once. A pointer move only asks the plan for the slot
// under the card's centre, and a slot change only sets the rows' targets (`SidebarGroupDragPlan.layout`). A group
// drag reorders top-level blocks only (u9772): it never drops into another group.
extension SidebarListViewComponents {
    /// Freezes the drag of a lifted group (`lifted`: its rows, `card`: the lifted card's frame) and cuts the card
    /// to its header and three rows on the move spring. Call with the drag set and its acceptance table taken.
    func beginGroupDrag(_ drag: Drag, lifted rows: [SidebarRow], card: NSRect) {
        let first = rows.first?.y ?? card.minY, last = rows.last?.maxY ?? card.maxY
        let cut = SidebarGroupDragPlan.cardHeight(rows: rows.map { $0.y...$0.maxY }, top: first, full: last - first)
        let shown = displayed.rows.filter { !drag.hiddenKeys.contains($0.key) && $0.height > 0 }
        // The spacing the list keeps around the group, as it is drawn at lift.
        let trail = shown.first { $0.y >= last - 0.5 }.map { $0.y - last } ?? displayed.rowSpacing
        let lead = shown.last { $0.maxY <= first + 0.5 }.map { first - $0.maxY } ?? displayed.rowSpacing
        let carried = rows.map { row in
            var row = row
            row.y -= first
            return row
        }
        drag.group = groupDrag(drag, groupTop: first, card: cut, lead: lead, trail: trail, carried: carried)
        if cut < last - first - 0.5 { drag.lift.cap(to: card.height - (last - first - cut), fade: min(SidebarGroupDragPlan.fade, cut / 3)) }
    }

    /// A pointer move of a held group drag: the slot under the card's centre; the rows move only when it changes.
    func updateGroupDrag(_ drag: Drag) {
        if drag.group.map({ $0.revision != model.sectionsRevision }) == true { rebaseGroupDrag(drag) }
        guard let group = drag.group else { return }
        let slot = group.plan.slot(cardCentre: groupCardCentre(drag, group))
        guard slot != group.slot else { return }
        setGroupSlot(drag, slot)
        showDragLayout()
    }

    /// The model changed under a held group drag (a batch, an adopt, a close): the base is laid out again and the
    /// card keeps its cut; the slot is the new base's under the card.
    func rebaseGroupDrag(_ drag: Drag) {
        guard let plan = drag.group?.plan else { return }
        let group = groupDrag(drag, groupTop: plan.groupTop, card: plan.card, lead: plan.lead, trail: plan.trail, carried: plan.carried)
        drag.group = group
        setGroupSlot(drag, group.plan.slot(cardCentre: groupCardCentre(drag, group)))
    }

    /// The cut card's centre: its header's top (the card may reach a little above it, `SidebarListLift.blockFrame`)
    /// plus half the cut height.
    private func groupCardCentre(_ drag: Drag, _ group: SidebarGroupDrag) -> CGFloat {
        drag.lift.frame.minY + (group.plan.groupTop - drag.restFrame.minY) + group.plan.card / 2
    }

    /// Puts the card in `slot`: the drop it makes there (none accepted: back where it came from).
    private func setGroupSlot(_ drag: Drag, _ slot: Int) {
        guard var group = drag.group else { return }
        group.slot = slot
        drag.group = group
        let drop = group.drops[slot]
        drag.target = drop.map { .position($0.position) } ?? drag.origin.map(DropTarget.position)
        drag.docTarget = drop?.doc
    }

    /// The landing frame of a dropped group: its slot's top at the cut card's height (the frame the drawn list leaves
    /// for it). The whole group shows once the model does (`landSettled` grows the card to the group's frame).
    func groupSlotFrame(_ drag: Drag) -> NSRect? {
        guard let group = drag.group else { return nil }
        let card = drag.lift.frame
        // The card may start a little above the header (its members' line, `SidebarListLift.blockFrame`): the lifted
        // block's top as it stood, less the header's.
        let above = group.plan.groupTop - drag.restFrame.minY
        return NSRect(x: card.minX, y: group.plan.top(of: group.slot) - above, width: card.width, height: card.height)
    }

    /// The base (the list as drawn without the dragged group), its blocks and each slot's drop.
    private func groupDrag(_ drag: Drag, groupTop: CGFloat, card: CGFloat, lead: CGFloat, trail: CGFloat,
                           carried: [SidebarRow]) -> SidebarGroupDrag {
        let base = SidebarLayout.make(sections: listSections, metrics: metrics, options: options(includeGap: false))
        let blocks = SidebarGroupDragPlan.blocks(of: base.rows)
        let geometry = model.docDrag.map { $0.geometry(base, width: bounds.width, acceptance: drag.docAcceptance, blocks: blockBases()).0 }
        let section = drag.origin?.section
        // A slot's drop goes after the block above it, else before the block below it.
        let drops = (0...blocks.count).map { slot in
            (slot > 0 ? groupDrop(beside: blocks[slot - 1], after: true, geometry: geometry, section: section) : nil)
                ?? (slot < blocks.count ? groupDrop(beside: blocks[slot], after: false, geometry: geometry, section: section) : nil)
        }
        let plan = SidebarGroupDragPlan(blocks: blocks, groupTop: groupTop, card: card, lead: lead, trail: trail,
                                        allowed: drops.map { $0 != nil }, carried: carried)
        return SidebarGroupDrag(base: base, plan: plan, drops: drops, revision: model.sectionsRevision, slot: plan.origin)
    }

    /// A drop right after (or before) `block`: first in a section after its header, beside a top-level row's item.
    /// On the document, only where the acceptance table takes it; without one, only in the group's own section
    /// (the model's reorder moves a group among its section's nodes).
    private func groupDrop(beside block: SidebarGroupDragPlan.Block, after: Bool, geometry: SidebarDragGeometry?,
                           section: SectionID?) -> SidebarGroupDrag.Drop? {
        let head = block.head
        let position: DropPosition
        let key: String?
        switch head.key {
        case .section, .emptySection:
            guard after else { return nil } // before a section's header is after the block above it
            position = DropPosition(section: head.section, index: 0)
            key = model.docDrag?.section(head.section)
        case .group, .workspace, .item:
            position = DropPosition(section: head.section, index: after ? block.nextIndex : head.siblingIndex)
            key = model.docDrag?.item(head.key)
        default:
            return nil
        }
        guard let geometry else { return head.section == section ? SidebarGroupDrag.Drop(position: position) : nil }
        guard let key, let hit = geometry.beside(key, after: after), let target = hit.target else { return nil }
        return SidebarGroupDrag.Drop(position: position, doc: target)
    }
}
