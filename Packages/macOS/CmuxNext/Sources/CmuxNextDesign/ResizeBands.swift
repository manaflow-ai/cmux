public import AppKit
import ObjectiveC

/// The resize handles' bands of one window, so a scroller knows where a handle has priority over it.
///
/// A scroll view's edge scroller and a resize handle (the sidebar's, a pane divider's) can share
/// columns. The rule (Leo 2026-11-22: "when you're near the thumb and the sliding repositioner, it
/// gets confused and sometimes goes to the thumb instead of the dragger"): a press inside a handle's
/// band always resizes, whatever the scroller shows. Each handle registers its view with its window
/// (the window keeps the set, no global state); a ``ThinScroller`` leaves the part of its grab zone
/// under a band to the handle, for the press and for the pointer (it does not widen the knob there),
/// so both answer the same columns.
@MainActor
public final class ResizeBands {
    private let bands = NSHashTable<NSView>.weakObjects()
    /// The association's key: this class's own address, no stored global.
    private static var key: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(ResizeBands.self as AnyObject).toOpaque()) }

    private static func of(_ window: NSWindow) -> ResizeBands {
        if let made = objc_getAssociatedObject(window, key) as? ResizeBands { return made }
        let made = ResizeBands()
        objc_setAssociatedObject(window, key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// Registers `band`, a view whose bounds are a resize handle's hit area, with its window.
    /// Call it from `viewDidMoveToWindow`; weak and idempotent.
    public static func register(_ band: NSView) {
        guard let window = band.window else { return }
        of(window).bands.add(band)
    }

    /// A shown, registered band of `window` covers `windowPoint` (half-open, as `CGRect.contains`).
    public static func claims(_ windowPoint: CGPoint, in window: NSWindow) -> Bool {
        guard let set = objc_getAssociatedObject(window, key) as? ResizeBands else { return false }
        return set.bands.allObjects.contains { band in
            band.window === window && !band.isHiddenOrHasHiddenAncestor
                && band.convert(band.bounds, to: nil).contains(windowPoint)
        }
    }
}
