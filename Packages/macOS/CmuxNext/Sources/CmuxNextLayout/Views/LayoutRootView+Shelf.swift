public import AppKit

/// A view built ahead for a pane that does not exist yet (the App's spare pane, RESIZE VIDEOS F1) waits on a shelf
/// inside the layout: a zero-size view under every screen that clips its layer. The view's layers are made, drawn and
/// committed at idle, it shows nothing, takes no click and is hidden from accessibility, and a pane's host takes it
/// from the shelf in the turn that mounts the pane, without leaving the window.
extension LayoutRootView {
    private static let shelfID = NSUserInterfaceItemIdentifier("cmux.layoutShelf")

    /// Puts `view` on the shelf (made the first time).
    public func shelve(_ view: NSView) {
        let shelf = subviews.first { $0.identifier == Self.shelfID } ?? {
            let shelf = NSView(frame: .zero)
            shelf.identifier = Self.shelfID
            shelf.wantsLayer = true
            shelf.layer?.masksToBounds = true
            shelf.setAccessibilityHidden(true)
            addSubview(shelf, positioned: .below, relativeTo: nil)
            return shelf
        }()
        shelf.addSubview(view)
    }

    /// Takes `view` off the shelf, when it is still there (a view a pane's host took is not).
    public func unshelve(_ view: NSView) {
        if view.superview?.identifier == Self.shelfID { view.removeFromSuperview() }
    }
}
