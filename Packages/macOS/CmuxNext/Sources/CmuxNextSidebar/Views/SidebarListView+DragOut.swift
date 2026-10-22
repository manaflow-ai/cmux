import AppKit
import CmuxNextDesign

extension SidebarViewComponents {
    /// Whether a dragged document item (its id) is removed when it is dropped beside the sidebar
    /// (the Chief, Leo 2026-10-21: drag it out to take it off the sidebar). Nil keeps every item in.
    public var removesOnDragOut: ((String) -> Bool)? {
        get { list.removesOnDragOut }
        set { list.removesOnDragOut = newValue }
    }

    /// Removes the item a drag dropped beside the sidebar (`removesOnDragOut` said yes).
    public var onDragOutRemove: ((String) -> Void)? {
        get { list.onDragOutRemove }
        set { list.onDragOutRemove = newValue }
    }
}

extension SidebarListViewComponents {
    /// While an item the App removes on a drag out (`removesOnDragOut`) is past the sidebar's side edges,
    /// its card dims and a release there removes it. True while it is out there (the list keeps its slot).
    func holdsDragOut(_ drag: Drag, windowPoint: NSPoint) -> Bool {
        guard case let .item(id) = drag.payload, removesOnDragOut?(id) == true, let scroll = enclosingScrollView else { return false }
        let sidebarFrame = scroll.convert(scroll.bounds, to: nil)
        let slack = Metrics.space6
        let outside = windowPoint.x > sidebarFrame.maxX + slack || windowPoint.x < sidebarFrame.minX - slack
        if outside != drag.removesOnDrop {
            drag.removesOnDrop = outside
            drag.lift.setRefused(outside || (drag.docItems != nil ? drag.docTarget == nil : drag.target == nil))
        }
        return outside
    }

    /// Ends a drag released beside the sidebar by removing its item; false for any other drag.
    func finishDragOut(_ drag: Drag) -> Bool {
        guard drag.removesOnDrop, case let .item(id) = drag.payload else { return false }
        SidebarListPinDrop.end(self)
        // A band tile's press drags nothing more, and its region lets the press go (as `cancelDrag`).
        if let source = drag.tileSource {
            drag.tileRegion?.docSpentPress = source.item
            drag.tileRegion?.endDocPress()
        }
        onDragOutRemove?(id)
        abandonDrag(drag)
        return true
    }
}
