import AppKit
import CmuxNextDesign

/// One item or section drag in a region (R77).
final class SidebarRegionDrag {
    let subject: SidebarRegionDragSubject
    let lift: DragLiftView
    /// Where the pointer grabbed the card, from its origin.
    let grab: CGPoint
    /// The card follows the pointer sideways too (an item of a flowed section).
    let followsBothAxes: Bool
    /// The subject's own views, hidden under the card until it lands.
    let hidden: [NSView]
    /// A workspace item over the workspace list: the drop takes it out of the band.
    var dropsToList = false

    init(subject: SidebarRegionDragSubject, lift: DragLiftView, grab: CGPoint, followsBothAxes: Bool, hidden: [NSView]) {
        self.subject = subject
        self.lift = lift
        self.grab = grab
        self.followsBothAxes = followsBothAxes
        self.hidden = hidden
    }

    /// Whether a drag of `subject` moves on both axes: an item whose
    /// section flows (tiles, a grid, one line) has neighbors beside it, so
    /// its card follows the pointer sideways; list rows and section
    /// headers only move up and down.
    static func followsBothAxes(_ subject: SidebarRegionDragSubject, sections: [LayoutSection], look: SectionsLookVariant) -> Bool {
        guard case let .item(id) = subject, let (s, _) = SidebarLayoutReducer.locate(id, in: sections) else { return false }
        return SectionFlow.mode(sections[s], look: look) != nil
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
        guard allowsDrag else { return false }
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
        let host = liftHost ?? self
        let lift = SidebarReorderLift.lift(card, frame: host.convert(frame, from: self), in: host)
        let both = SidebarRegionDrag.followsBothAxes(subject, sections: content.sections, look: content.look)
        reorder = SidebarRegionDrag(subject: subject, lift: lift, grab: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                                    followsBothAxes: both, hidden: hidden)
        reorderSections = content.sections
    }

    func updateDrag(to point: NSPoint) {
        guard let drag = reorder, let sections = reorderSections else { return }
        // The card lives in the lift host; it is placed and read back in this region's coordinates.
        let host = drag.lift.superview ?? self
        let origin = host.convert(CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y), from: self)
        if drag.followsBothAxes {
            SidebarReorderLift.follow(drag.lift, origin: origin, visible: host.visibleRect)
        } else {
            SidebarReorderLift.follow(drag.lift, top: origin.y, visible: host.visibleRect)
        }
        if isWorkspaceItem(drag.subject), let probe = dropToListProbe {
            drag.dropsToList = probe(convert(point, to: nil))
            if drag.dropsToList {
                // Over the list the band shows the drop's outcome: itself
                // without the tile (cx-odqn: no flight back, no gap after).
                let without = content?.sections.map { section in
                    var section = section
                    section.items.removeAll { $0.id == drag.subject.itemID }
                    return section
                }
                if reorderSections != without { reorderSections = without; relayout(animated: true) }
                return
            }
        }
        let card = convert(drag.lift.frame, from: host)
        // The card's middle decides (as the list, nxdog30): what it covers more than half of makes way.
        // Sideways, the card's middle decides too, so a tile makes way when the card covers half of it.
        let probe = CGPoint(x: drag.followsBothAxes ? card.midX : point.x, y: card.midY)
        guard let moved = SidebarRegionReorder.move(drag.subject, at: probe, display: layoutResult, sections: sections) else { return }
        reorderSections = moved
        relayout(animated: true)
    }

    func finishDrag() {
        guard let drag = reorder else { return }
        reorder = nil
        _ = dropToListProbe?(nil)
        if drag.dropsToList, case let .item(id) = drag.subject {
            onDropToList?(id)
            return land(drag)
        }
        if let sections = reorderSections, sections != content?.sections { onReorder?(drag.subject, sections) }
        land(drag)
    }

    func cancelDrag() {
        guard let drag = reorder else { return }
        reorder = nil
        _ = dropToListProbe?(nil)
        reorderSections = nil
        relayout(animated: true)
        land(drag)
    }

    /// The card settles into the slot the region already shows (a tile
    /// dropped on the list has none there: it settles where it is); then
    /// the region shows its content again (by then the dropped order).
    private func land(_ drag: SidebarRegionDrag) {
        let host = drag.lift.superview ?? self
        SidebarReorderLift.land(drag.lift, at: frame(of: drag.subject).map { host.convert($0, from: self) }) { [weak self] in
            for view in drag.hidden { view.alphaValue = 1 }
            guard let self, self.reorder == nil else { return }
            self.reorderSections = nil
            self.relayout(animated: true)
        }
    }

    /// A workspace tile or top row (drop-to-list unpins it); other items stay in the band.
    private func isWorkspaceItem(_ subject: SidebarRegionDragSubject) -> Bool {
        guard case let .item(id) = subject else { return false }
        return content?.sections.lazy.flatMap(\.items).first { $0.id == id }?.ref.kind == LayoutItemRef.workspaceKind
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

extension SidebarRegionDragSubject {
    /// The dragged item, or nil for a section.
    var itemID: LayoutItemID? {
        if case let .item(id) = self { id } else { nil }
    }
}
