public import AppKit

/// A pane whose ground another view paints for it: a floating pane with a see-through background, whose card
/// paints the one ground under the pane at the look's opacity. While ``ownsContentGround`` is true, each view
/// inside the pane that paints a ground (``PaneGroundFollowing``: the content area, a terminal's host) paints
/// none, so the text stays solid over the see-through ground.
@MainActor
public protocol PaneGroundOwning: NSView {
    /// Whether the views inside paint no ground now.
    var ownsContentGround: Bool { get }
    /// A view inside has another ground to give now (its theme changed, its program set a background).
    func contentGroundDidChange()
    /// Whether an opaque ground lies under the pane while the views inside paint their own (a floating pane's card
    /// with a solid background). In a see-through window those views are then not over the window's one sheet: a
    /// ground that a view paints at the window's tint for that sheet is opaque here.
    var hasSolidGroundUnder: Bool { get }
}

public extension PaneGroundOwning {
    /// No opaque ground of the owner's lies under the pane, unless the owner says so.
    var hasSolidGroundUnder: Bool { false }
}

/// A view inside a pane that paints a ground under the pane's content and paints none while an owner above
/// paints it (``PaneGroundOwning``).
@MainActor
public protocol PaneGroundFollowing: NSView {
    /// The owner above started or stopped to paint the ground: paint again.
    func paneGroundOwnerChanged()
}

public extension NSView {
    /// The nearest view above this one that can paint its pane's ground. A walk of the superviews, O(depth): read
    /// when a ground is painted, not in each frame.
    var paneGroundOwner: (any PaneGroundOwning)? {
        var view = superview
        while let current = view {
            if let owner = current as? any PaneGroundOwning { return owner }
            view = current.superview
        }
        return nil
    }

    /// Whether a view above paints this view's ground now.
    var paneGroundIsOwnedAbove: Bool { paneGroundOwner?.ownsContentGround ?? false }

    /// Tells each view below this one that paints a ground to paint again (the owner's state changed).
    func tellPaneGroundFollowers() {
        for view in subviews {
            (view as? any PaneGroundFollowing)?.paneGroundOwnerChanged()
            view.tellPaneGroundFollowers()
        }
    }
}
