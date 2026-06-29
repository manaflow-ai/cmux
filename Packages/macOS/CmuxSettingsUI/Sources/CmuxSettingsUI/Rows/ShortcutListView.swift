import AppKit

/// Bounded inner scroll view for the shortcut list. Forwards a wheel event to
/// the enclosing page scroll view once the table is at its scroll limit so the
/// bounded box reads as one continuous page (the rest falls through to `super`).
final class ShortcutListScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        let y = contentView.bounds.origin.y
        let maxY = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
        let canScrollUp = dy < 0 && y < maxY        // content moves up
        let canScrollDown = dy > 0 && y > 0          // content moves down
        if dy == 0 || canScrollUp || canScrollDown {
            super.scrollWheel(with: event)
            return
        }
        if let page = ancestorPageScrollView() {
            page.scrollWheel(with: event)            // forward unchanged at the limit
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// First enclosing `NSScrollView` above this one (the SwiftUI page scroll view).
    private func ancestorPageScrollView() -> NSScrollView? {
        var view = superview
        while let v = view {
            if let scroll = v as? NSScrollView, scroll !== self { return scroll }
            view = v.superview
        }
        return nil
    }
}
