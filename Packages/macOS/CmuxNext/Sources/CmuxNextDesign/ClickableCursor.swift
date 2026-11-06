public import AppKit

/// The shared chrome button: it shows the arrow, enabled or disabled, as native macOS controls do
/// (user 2026-10-30: "change all pointers back to cursor-default"; this replaces Leo's 2026-10-21
/// pointing hand). The shared chrome buttons (toolbar band, pane toolbar, tab bar, sidebar,
/// dialogs, toasts) inherit it, so they share one cursor rule.
///
/// It registers no cursor rect of its own, so the arrow of the view under
/// it shows. A change of `isEnabled` still tells a `ClickableCursorHost` (the browser toolbar row,
/// which sets the cursor itself while a Chromium child window has the key).
/// `scripts/cmux-next/check-default-cursor.py` keeps a new pointing hand out.
open class ClickableButton: NSButton {
    override open var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            // AppKit rebuilds cursor rects only in the key window: a host that sets the cursor
            // itself (a toolbar row while a child window has the key) sets it again now.
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? any ClickableCursorHost {
                    host.clickableStateDidChange(self)
                    return
                }
                ancestor = view.superview
            }
        }
    }

    /// Where the pointer at `screenPoint` is in `window`'s coordinates, while `window` is the top
    /// window under it (`topWindowNumber`, `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
    /// outside tests); nil while another window covers that point.
    public static func pointer(in window: NSWindow, screenPoint: NSPoint, topWindowNumber: @MainActor (NSPoint) -> Int) -> NSPoint? {
        guard topWindowNumber(screenPoint) == window.windowNumber else { return nil }
        return window.convertPoint(fromScreen: screenPoint)
    }

    /// `pointer(in:screenPoint:topWindowNumber:)` for the real pointer and window list.
    public static func currentPointer(in window: NSWindow) -> NSPoint? {
        pointer(in: window, screenPoint: NSEvent.mouseLocation) { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    }

    /// Where a clickable view's cursor rect goes: its visible rect, as `addCursorRect` requires, so
    /// a button clipped by a scroller or a narrow container claims only what shows; nil while the
    /// view is hidden or nothing of it shows. `visibleRect` alone is not enough: a view that does
    /// not clip to its bounds (the macOS 14 default) reports the visible part of its ancestors,
    /// so the rect is cut to the view's own bounds.
    public static func cursorRect(of view: NSView) -> NSRect? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.visibleRect.intersection(view.bounds)
        return rect.isEmpty ? nil : rect
    }
}

/// A view that sets the cursor over its clickable subviews itself (on pointer moves), not only
/// through their cursor rects: a `ClickableButton` inside it tells it when it is enabled or
/// disabled, so a still pointer shows the new cursor at once.
@MainActor
public protocol ClickableCursorHost: AnyObject {
    func clickableStateDidChange(_ view: NSView)
}
