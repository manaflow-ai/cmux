import AppKit

/// Whether the user is pointing into or dragging within a workspace sidebar.
///
/// Automatic activity reordering defers while this is true so a row never
/// jumps under the cursor and a drop target never shifts mid-drag. Hover is
/// read live from each registered table instead of tracked from enter/exit
/// events, because tracking events stop during drags and context menus and
/// a missed exit would otherwise block reordering until the next hover.
@MainActor
final class SidebarReorderInteractionState {
    static let shared = SidebarReorderInteractionState()

    private let tables = NSHashTable<NSView>.weakObjects()
    private let dragOwners = NSHashTable<AnyObject>.weakObjects()

    /// Registers a sidebar table whose bounds count as the sidebar.
    func register(table: NSView) {
        tables.add(table)
    }

    /// Records a workspace drag that started or ended in a sidebar.
    func setDragging(_ isDragging: Bool, owner: AnyObject) {
        if isDragging {
            dragOwners.add(owner)
        } else {
            dragOwners.remove(owner)
        }
    }

    /// A pointer resting over the sidebar this long no longer counts as
    /// interacting: clicking a row and then typing leaves the pointer parked
    /// there, and that should not hold every reorder back.
    static let restingPointerGrace: TimeInterval = 5

    /// True while a sidebar drag runs, or while the pointer has recently moved
    /// or scrolled over a visible sidebar table that is the frontmost window at that point.
    var isInteracting: Bool {
        // A drag holds a mouse button down. Checking that as well means a
        // drag end AppKit never reported cannot block reordering for good.
        if NSEvent.pressedMouseButtons != 0, dragOwners.allObjects.isEmpty == false { return true }
        let secondsSincePointerUsed = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        )
        guard secondsSincePointerUsed < Self.restingPointerGrace else { return false }
        let screenPoint = NSEvent.mouseLocation
        let frontWindowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return tables.allObjects.contains { table in
            guard !table.isHiddenOrHasHiddenAncestor,
                  let window = table.window, window.isVisible,
                  window.windowNumber == frontWindowNumber else { return false }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return table.visibleRect.contains(table.convert(windowPoint, from: nil))
        }
    }
}
