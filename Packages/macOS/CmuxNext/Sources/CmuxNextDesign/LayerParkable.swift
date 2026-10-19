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

/// A view that reacts when it goes out of sight or back (`isOutOfSight`), as it does on
/// `viewDidHide` / `viewDidUnhide`: AppKit sends those for a hidden-state change only, so a parked
/// view tells its subtree itself (`notifyOutOfSightChange`).
@MainActor
public protocol OutOfSightObserving: NSView {
    func outOfSightDidChange()
}

extension LayerParkable {
    /// Tells every `OutOfSightObserving` view in this view's subtree (itself included) that it
    /// went out of sight or came back. Call it when `isParked` changes.
    public func notifyOutOfSightChange() {
        var pending: [NSView] = [self]
        while let view = pending.popLast() {
            (view as? OutOfSightObserving)?.outOfSightDidChange()
            pending.append(contentsOf: view.subviews)
        }
    }
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
