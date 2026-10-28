public import AppKit

/// A page held at the size its pane's spring rests at (``SpringPageResize/once``): set at the spring's
/// start (``PaneMotionTargeting``), dropped when it lands (``PaneMotionSettling``).
public nonisolated struct SpringPageHold: Equatable, Sendable {
    /// The page's size when the spring lands.
    public var size: CGSize

    /// The hold of a view of `size` whose area will rest `sizeChange` larger.
    public init(size: CGSize, sizeChange: CGSize) {
        self.size = CGSize(width: max(0, size.width + sizeChange.width), height: max(0, size.height + sizeChange.height))
    }

    /// The held page's frame in a container with `bounds`: at its top-left, where a page's layer tree keeps
    /// its last frame while a frame at a new size comes (Chromium's flipped layers, WebKit's top-left origin).
    public func rect(in bounds: CGRect, flipped: Bool) -> CGRect {
        CGRect(x: bounds.minX, y: flipped ? bounds.minY : bounds.maxY - size.height, width: size.width, height: size.height)
    }
}

public extension NSView {
    /// The nearest enclosing ``RestingPlacement`` (a pane host); nil outside a pane.
    var enclosingRestingPlacement: (any RestingPlacement)? {
        var ancestor = superview
        while let view = ancestor {
            if let placement = view as? any RestingPlacement { return placement }
            ancestor = view.superview
        }
        return nil
    }
}
