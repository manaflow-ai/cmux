public import AppKit

/// A button that shows the pointing hand while the pointer is over it and it is enabled, and the
/// arrow while it is disabled (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD
/// ALSO SEE IT AS CLICKABLE"). The shared chrome buttons (toolbar band, pane toolbar, tab bar,
/// sidebar, dialogs, toasts) inherit it, so each says it can be clicked the same way.
///
/// A cursor rect in the key window: AppKit owns the rect and drops it when the button hides,
/// leaves its window or scrolls out of view, so no pushed cursor is ever left behind. A change of
/// `isEnabled` rebuilds it at once. Cursor rects do nothing while another window has the key (a
/// Chromium page is a child window that takes it); there only a `ClickableCursorHost` (the
/// browser toolbar row) sets the hand itself.
open class ClickableButton: NSButton {
    /// The cursor over a button: the pointing hand while enabled, none (the arrow) while disabled.
    public static func hoverCursor(isEnabled: Bool) -> NSCursor? { isEnabled ? .pointingHand : nil }

    /// This button's cursor now (`hoverCursor(isEnabled:)`).
    public var hoverCursor: NSCursor? { Self.hoverCursor(isEnabled: isEnabled) }

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

    override open func resetCursorRects() {
        super.resetCursorRects()
        if let hoverCursor, let rect = Self.cursorRect(of: self) { addCursorRect(rect, cursor: hoverCursor) }
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

/// The macOS 14 fallback's cursor stack state: the hand is pushed exactly while the view is
/// hovered and enabled. Each update returns the one push or pop that keeps it so, or nil.
struct ClickableCursorHover: Equatable {
    enum Change: Equatable { case push, pop }

    private(set) var hovering = false
    private(set) var pushed = false

    mutating func update(hovering: Bool, enabled: Bool) -> Change? {
        self.hovering = hovering
        let wanted = hovering && enabled
        guard wanted != pushed else { return nil }
        pushed = wanted
        return wanted ? .push : .pop
    }
}
