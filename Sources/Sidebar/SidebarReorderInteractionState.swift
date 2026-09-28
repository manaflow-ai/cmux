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

    /// True while a sidebar drag runs or the pointer is over a visible sidebar
    /// table that is the frontmost window at that point.
    var isInteracting: Bool {
        if dragOwners.allObjects.isEmpty == false { return true }
        let screenPoint = NSEvent.mouseLocation
        let frontWindowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return tables.allObjects.contains { table in
            guard let window = table.window, window.isVisible,
                  window.windowNumber == frontWindowNumber else { return false }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return table.visibleRect.contains(table.convert(windowPoint, from: nil))
        }
    }
}
