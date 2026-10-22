import AppKit

// A dragged group's drop on the sidebar document (u2455, u9772): the gap moves among the list's top-level blocks by the
// card's edges (`SidebarGroupReorder`), and the drop goes beside the block the gap stands next to: after the block above
// it, else before the block below it. Never into a group or beside one of its members: since nested groups the
// acceptance table takes those, and a reorder that nested the group into the group it passed is not what the list shows.
extension SidebarListViewComponents {
    /// Shows the gap at block `index` (blocks of the list without the dragged group) and sets the drop it makes.
    func showGroupReorder(_ drag: Drag, index: Int, geometry: SidebarDragGeometry, displayY: CGFloat, point: NSPoint) {
        guard let doc = model.docDrag else { return }
        let anchors = drag.groupAnchors
        func beside(_ i: Int, after: Bool) -> (SidebarDragGeometry.Hit, SidebarGroupReorder.Anchor)? {
            guard anchors.indices.contains(i) else { return nil }
            let head = anchors[i].head
            let key: String? = switch head.key {
            case .section, .emptySection: doc.section(head.section)
            default: doc.item(head.key)
            }
            return key.flatMap { geometry.beside($0, after: after) }.map { ($0, anchors[i]) }
        }
        guard let (hit, anchor) = beside(index - 1, after: true) ?? beside(index, after: false) else {
            // Nowhere to drop beside this block: the last open gap stays (the drop goes there), else the card dims.
            if drag.docTarget == nil { drag.lift.setRefused(true) }
            return
        }
        drag.probe = SidebarDropProbe(hit, displayY: displayY, baseY: hit.slot.frame.midY)
        drag.docTarget = hit.target
        drag.lift.setRefused(hit.target == nil)
        let head = anchor.head
        let target: DropTarget = switch (head.key, hit.zone) {
        case (.section, _), (.emptySection, _):
            .position(DropPosition(section: head.section, index: 0))
        case (_, .after):
            // Past the whole block: a group's subgroups are nodes of the section after it.
            .position(DropPosition(section: head.section, index: anchor.nextIndex))
        default:
            .position(DropPosition(section: head.section, index: head.siblingIndex))
        }
        guard target != drag.target || drag.blockTarget != nil else { return }
        drag.target = target
        drag.blockTarget = nil
        showDragLayout()
        morphLift(drag, point: point)
    }
}
