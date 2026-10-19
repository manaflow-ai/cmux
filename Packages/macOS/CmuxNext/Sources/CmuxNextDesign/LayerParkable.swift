public import AppKit

/// A view kept in its window but out of sight by its layer (`isParked`), not by AppKit's hidden
/// state. A hidden-state change of a view that touches a transparent titlebar makes AppKit send the
/// window's titlebar drag shapes to the window server again, and the next Core Animation commit then
/// waits on a window-server fence (cx-8w027.19: one per tab switch). A parked view changes nothing
/// AppKit tracks; the code that asks whether a view shows reads `isOutOfSight`.
@MainActor
public protocol LayerParkable: NSView {
    var isParked: Bool { get }
    /// Parks the view in place or shows it again. A view that cannot park by its layer now (a
    /// control of its own would stay live) may use AppKit's hidden state instead.
    func park(_ parked: Bool)
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
    /// Out of sight in place: a `LayerParkable` view parks itself, any other view hides.
    public func parkInPlace(_ parked: Bool) {
        if let view = self as? LayerParkable { view.park(parked) } else { isHidden = parked }
    }

    /// Hidden or parked itself (not through an ancestor).
    public var isParkedOrHidden: Bool { isHidden || (self as? LayerParkable)?.isParked == true }

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

/// A container whose parked subviews (`LayerParkable`) are out of hit testing and out of its
/// accessibility children, as hidden ones are (a pane's content host).
public final class LayerParkingHostView: NSView {
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, NSMouseInRect(point, frame, superview?.isFlipped ?? false) else { return nil }
        let local = convert(point, from: superview)
        for subview in subviews.reversed() where (subview as? LayerParkable)?.isParked != true {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }

    override public func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { child in
            guard let view = child as? NSView else { return true }
            return !view.isOutOfSight
        }
    }
}
