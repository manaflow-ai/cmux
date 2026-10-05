import AppKit
import CmuxNextDesign

/// One item or section drag in a region (R77).
final class SidebarRegionDrag {
    let subject: SidebarRegionDragSubject
    let lift: DragLiftView
    let grabOffsetY: CGFloat
    /// The subject's own views, hidden under the card until it lands.
    let hidden: [NSView]

    init(subject: SidebarRegionDragSubject, lift: DragLiftView, grabOffsetY: CGFloat, hidden: [NSView]) {
        self.subject = subject
        self.lift = lift
        self.grabOffsetY = grabOffsetY
        self.hidden = hidden
    }
}

// The item sections reorder in place like the workspace list (R77, one
// drag model: SidebarRegionReorder for the order, SidebarReorderLift for
// the card): the region shows the moved order while the card follows the
// pointer, and the drop sends that order once.
extension SidebarRegionView {
    /// The sections in the order the region shows now.
    var displayedSections: [LayoutSection] { reorderSections ?? content?.sections ?? [] }

    /// A press moved (window points). True once a drag runs.
    func dragMoved(_ subject: SidebarRegionDragSubject, from start: NSPoint, _ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if reorder == nil {
            let origin = convert(start, from: nil)
            guard hypot(point.x - origin.x, point.y - origin.y) >= SidebarStyle.dragThreshold else { return false }
            beginDrag(subject, at: origin)
        }
        updateDrag(to: point)
        return reorder != nil
    }

    func beginDrag(_ subject: SidebarRegionDragSubject, at point: NSPoint) {
        guard reorder == nil, let content, let frame = frame(of: subject) else { return }
        let card = snapshot(frame)
        let hidden = views(of: subject)
        for view in hidden { view.alphaValue = 0 }
        let lift = SidebarReorderLift.lift(card, frame: frame, in: self)
        reorder = SidebarRegionDrag(subject: subject, lift: lift, grabOffsetY: point.y - frame.minY, hidden: hidden)
        reorderSections = content.sections
    }

    func updateDrag(to point: NSPoint) {
        guard let drag = reorder, let sections = reorderSections else { return }
        SidebarReorderLift.follow(drag.lift, top: point.y - drag.grabOffsetY, visible: visibleRect)
        // The card's middle decides (as the list, nxdog30): what it covers more than half of makes way.
        let probe = CGPoint(x: point.x, y: drag.lift.frame.midY)
        guard let moved = SidebarRegionReorder.move(drag.subject, at: probe, display: layoutResult, sections: sections) else { return }
        reorderSections = moved
        relayout(animated: true)
    }

    func finishDrag() {
        guard let drag = reorder else { return }
        reorder = nil
        if let sections = reorderSections, sections != content?.sections { onReorder?(drag.subject, sections) }
        land(drag)
    }

    func cancelDrag() {
        guard let drag = reorder else { return }
        reorder = nil
        reorderSections = nil
        relayout(animated: true)
        land(drag)
    }

    /// The card settles into the slot the region already shows; then the
    /// region shows its content again (by then the dropped order).
    private func land(_ drag: SidebarRegionDrag) {
        SidebarReorderLift.land(drag.lift, at: frame(of: drag.subject)) { [weak self] in
            for view in drag.hidden { view.alphaValue = 1 }
            guard let self, self.reorder == nil else { return }
            self.reorderSections = nil
            self.relayout(animated: true)
        }
    }

    private func frame(of subject: SidebarRegionDragSubject) -> CGRect? {
        switch subject {
        case let .item(id): layoutResult.rows.first { SidebarRegionReorder.item(of: $0)?.0 == id }?.frame
        case let .section(id): SidebarRegionReorder.frame(of: id, in: layoutResult)
        }
    }

    private func views(of subject: SidebarRegionDragSubject) -> [NSView] {
        switch subject {
        case let .item(id):
            return itemViews[id].map { [$0] } ?? []
        case let .section(id):
            let items = displayedSections.first { $0.id == id }?.items.compactMap { itemViews[$0.id] } ?? []
            return [headerViews[id], appViews[id]].compactMap { $0 } + items
        }
    }

    /// What `frame` shows now, as the card's content.
    private func snapshot(_ frame: CGRect) -> NSView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        if let rep = bitmapImageRepForCachingDisplay(in: frame) {
            cacheDisplay(in: frame, to: rep)
            let image = NSImage(size: frame.size)
            image.addRepresentation(rep)
            view.image = image
        }
        return view
    }
}
