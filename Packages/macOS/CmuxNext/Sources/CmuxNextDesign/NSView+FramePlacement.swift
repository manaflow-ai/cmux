public import AppKit

// RESIZE P0 11 M2: one constraint anywhere in a window (the sidebar's, the titlebar band's) makes AppKit give every
// view in it that translates its autoresizing mask an autoresizing constraint. Each frame change of such a view then
// updates its constraint in the window's engine and marks the window's frame view (`NSThemeFrame`) for layout, so the
// CA commit of every spring frame of a pane resize runs a whole-window layout pass (16 in 27 frames on the fleet).
// The pane tree places its views by frame (Chrome's views do the same), so it leaves the engine: a view out of it
// changes its frame with no constraint update and no window pass.
extension NSView {
    /// Takes this view and the views under it out of the window's Auto Layout engine: they stop translating their
    /// autoresizing masks into constraints. A view that holds a constraint of its own lays its subtree out with Auto
    /// Layout: it and its subtree keep translating. A container that places its subviews by frame calls this from
    /// `didAddSubview(_:)`.
    ///
    /// Autoresizing still applies to a view that leaves: AppKit resizes subviews by their masks when the container's
    /// frame is set in code, as the pane tree sets every frame in it.
    public func placeSubtreeByFrame() {
        var stack: [NSView] = [self]
        while let view = stack.popLast() {
            guard !view.holdsOwnConstraints else { continue }
            if view.translatesAutoresizingMaskIntoConstraints { view.translatesAutoresizingMaskIntoConstraints = false }
            stack.append(contentsOf: view.subviews)
        }
    }

    /// Whether this view holds a constraint other than a subview's autoresizing constraint.
    private var holdsOwnConstraints: Bool {
        constraints.contains { NSStringFromClass(type(of: $0)) != "NSAutoresizingMaskLayoutConstraint" }
    }
}
