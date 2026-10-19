public import AppKit

/// A view kept in its window but out of sight by its layer (`isParked`), not by AppKit's hidden
/// state. A hidden-state change of a view that touches a transparent titlebar makes AppKit send the
/// window's titlebar drag shapes to the window server again, and the next Core Animation commit then
/// waits on a window-server fence (cx-8w027.19: one per tab switch). A parked view changes nothing
/// AppKit tracks; the code that asks whether a view shows reads `isOutOfSight`.
@MainActor
public protocol LayerParkable: NSView {
    var isParked: Bool { get }
}

extension NSView {
    /// Hidden for AppKit, or inside a parked view (`LayerParkable`): out of sight either way.
    public var isOutOfSight: Bool {
        if isHiddenOrHasHiddenAncestor { return true }
        var view: NSView? = self
        while let current = view {
            if (current as? LayerParkable)?.isParked == true { return true }
            view = current.superview
        }
        return false
    }
}
