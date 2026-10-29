public import AppKit

extension NSView {
    /// Adds a tracking area over the view's visible rect that sends `cursorUpdate(with:)` when the
    /// pointer enters it; the view sets its cursor there instead of in cursor rects.
    /// Add it once, in init: `.inVisibleRect` follows every frame change by itself, so a resize or a
    /// drag rebuilds nothing, where AppKit rebuilt the window's cursor rects after each frame change.
    /// Chrome's views do the same: the view under the pointer names its cursor when the pointer
    /// reaches it (`ui/views/widget/root_view.cc`, `RootView::UpdateCursor`), nothing is laid out for it.
    /// `activity` defaults to the key window only, where cursor rects worked.
    @discardableResult
    public func addCursorUpdateArea(_ activity: NSTrackingArea.Options = .activeInKeyWindow) -> NSTrackingArea {
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .inVisibleRect, activity], owner: self)
        addTrackingArea(area)
        return area
    }
}
