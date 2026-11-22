public import AppKit

/// A view a toast must never cover (the Home composer and its buttons).
/// The toast host lifts each toast above every such view in its window
/// whose rect lies under the toast, and moves shown toasts when one posts
/// `cmuxToastAvoidanceDidChange`.
@MainActor
public protocol CmuxToastAvoiding: NSView {
    /// The rect toasts stay clear of, in the view's own coordinates.
    var toastAvoidanceRect: NSRect { get }
}

extension Notification.Name {
    /// Posted (object: the view) when a `CmuxToastAvoiding` view's rect
    /// changes, so shown toasts move clear of it.
    public static let cmuxToastAvoidanceDidChange = Notification.Name("CmuxNextDesign.toastAvoidanceDidChange")
}

extension CmuxToastOverlayHost {
    /// The gap between a toast and the view it avoids.
    static let avoidanceGap: CGFloat = 8

    /// The lowest bottom edge (window coordinates) a toast of `width`,
    /// centered in `bounds`, may take in `window`: above every avoided rect
    /// under it, else `bounds.minY`.
    static func floor(width: CGFloat, in bounds: NSRect, window: NSWindow) -> CGFloat {
        let band = NSRect(x: bounds.midX - width / 2 - avoidanceGap, y: bounds.minY,
                          width: width + 2 * avoidanceGap, height: bounds.height)
        var floor = bounds.minY
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01 else { return }
            if let avoiding = view as? any CmuxToastAvoiding {
                let rect = avoiding.convert(avoiding.toastAvoidanceRect, to: nil)
                if !rect.isEmpty, rect.intersects(band) { floor = max(floor, rect.maxY + avoidanceGap) }
            }
            view.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return floor
    }
}
