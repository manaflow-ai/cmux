import AppKit
import CmuxNextDesign
import QuartzCore

// A group's fold clips its members to the group's height (Leo 2026-11-02, on collapsing a group: "the collapsing group
// animation is kinda funky looking when the text all races up", "*compared to claude code"). The members stay where they
// are and fade, and each one is masked to the group's slot under its header, whose bottom edge moves on the same `.move`
// spring, from the same instant, as the rows below it: collapsing, the slot closes up and the rows below rise with its
// edge; opening, it opens down and they move down with it. No member slides past another and nothing draws under the
// rows below. The masks are render-server springs like the rows' (`SidebarDragSpring`): no layout per frame.
extension SidebarListViewComponents {
    /// Masks `rows` (the members leaving or opening, at their own frames) to the slot from `top` (the group header's
    /// bottom edge, list coordinates) down: `start` tall now, `end` tall when the fold ends (0 for a collapse, the members'
    /// height for an open). Only where the fold's springs run (movement on, in a window that draws); else the rows land
    /// as they do, with no mask.
    func clipFold(_ rows: [SidebarRowView], under top: CGFloat, from start: CGFloat, to end: CGFloat) {
        guard !rows.isEmpty, Motion.sidebar.animatesMovement, window != nil, Motion.canAnimate(in: self) else { return }
        // In the list's (flipped) coordinates: the slot starts at the header's bottom edge and grows down.
        func slot(_ height: CGFloat) -> NSRect { NSRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, height)) }
        for view in rows {
            guard let layer = view.layer else { continue }
            let target = view.convertToLayer(view.convert(slot(end), from: self))
            let mask: CALayer
            if let current = layer.mask, current.name == Self.foldClipName {
                // A fold turned mid-flight carries on from the mask's drawn edge (its springs keep their part).
                mask = current
            } else {
                mask = CALayer()
                mask.name = Self.foldClipName
                mask.backgroundColor = NSColor.black.cgColor
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mask.frame = view.convertToLayer(view.convert(slot(start), from: self))
                CATransaction.commit()
                layer.mask = mask
            }
            SidebarDragSpring.move(mask, to: target)
        }
    }

    static var foldClipName: String { "cmux.foldClip" }
}

extension SidebarRowView {
    /// Takes off a fold's mask (`clipFold`): the row's fold ended, or it leaves the list.
    func clearFoldClip() {
        guard let layer, layer.mask?.name == SidebarListView.foldClipName else { return }
        layer.mask = nil
    }
}
