import AppKit

/// Drop-to-pin from the workspace list (PINNED-ITEMS-END-TO-END P2): while a
/// workspace drag is over the tiles or the top rows of the band above, the
/// sidebar outlines the section that would take it, the card keeps
/// following the pointer and the list shows the drop's outcome: itself
/// without the rows (no empty slot, cx-odqn). The drop asks the App to add
/// the rows there and the card lands on the band slot that takes them; the
/// list keeps them out until the card has landed, by when the store shows
/// them in the band (or, refused, back in the list).
@MainActor enum SidebarListPinDrop {
    /// Probes the band under `windowPoint`; true while a section holds the drag.
    static func holds(_ list: SidebarListView, _ drag: SidebarListDrag, at windowPoint: NSPoint) -> Bool {
        guard case .workspaces = drag.payload, let sidebar = sidebar(of: list) else { return false }
        let wasHeld = drag.pinTarget != nil
        drag.pinTarget = SidebarPinDrops.pinDrop(sidebar, at: windowPoint)
        guard drag.pinTarget != nil else {
            // Back over the list: its slot opens again.
            if wasHeld { list.reload(animated: true) }
            return false
        }
        drag.lastWindowPoint = windowPoint
        let point = list.convert(windowPoint, from: nil)
        SidebarReorderLift.follow(drag.lift, top: point.y - drag.grabOffsetY, visible: list.visibleRect)
        list.autoscroll.stop()
        drag.lift.setRefused(false)
        // The slot a return to the list starts from; the list shows no slot meanwhile.
        drag.target = drag.origin.map(DropTarget.position)
        if !wasHeld { list.reload(animated: true) }
        return true
    }

    /// Ends the outline; for a drag a section holds, sends the drop and lands
    /// the card (true).
    static func finish(_ list: SidebarListView, _ drag: SidebarListDrag) -> Bool {
        end(list)
        guard let pin = drag.pinTarget, case let .workspaces(ids) = drag.payload else { return false }
        let slot = sidebar(of: list).flatMap { SidebarPinDrops.slot($0, for: pin) }.map { list.convert($0, from: nil) }
        list.drag = nil
        list.leaving.formUnion(ids)
        list.model.send(.dropOnLayoutSection(ids, section: pin.section, index: pin.index))
        list.suppressed = drag.hiddenKeys
        list.reload(animated: true)
        list.land(drag, at: slot) { [weak list] in
            list?.leaving.subtract(ids)
            list?.reload(animated: true)
        }
        return true
    }

    /// Hides the outline (a cancelled drag).
    static func end(_ list: SidebarListView) {
        if let sidebar = sidebar(of: list) { _ = SidebarPinDrops.pinDrop(sidebar, at: nil) }
    }

    /// The sidebar that holds the list (and the band above it).
    private static func sidebar(of list: NSView) -> SidebarView? {
        var view = list.superview
        while let current = view {
            if let sidebar = current as? SidebarView { return sidebar }
            view = current.superview
        }
        return nil
    }
}
