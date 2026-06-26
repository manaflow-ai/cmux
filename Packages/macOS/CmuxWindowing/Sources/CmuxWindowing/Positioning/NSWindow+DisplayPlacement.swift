public import AppKit

extension NSWindow {
    /// Reposition this window so it sits fully inside `screen`, keeping its
    /// current size (clamped to the display's visible frame) and centering it.
    ///
    /// Faithful lift of `AppDelegate.repositionPreservingSize(_:onto:)`. Width and
    /// height are clamped to the screen's `visibleFrame`, the centered origin is
    /// clamped so the whole frame stays on-screen, and the result is pixel-aligned
    /// via `integral` before `setFrame(_:display:animate:)` with `display: true`,
    /// `animate: false`.
    ///
    /// Deliberately does NOT raise, key, or activate the window: `window.display`
    /// is not a focus-intent command, so it must never steal macOS focus. Reads
    /// and mutates main-actor `NSWindow` / `NSScreen` state, so it is `@MainActor`.
    @MainActor
    public func cmuxRepositionPreservingSize(onto screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(self.frame.width, visible.width)
        let height = min(self.frame.height, visible.height)
        var origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height).integral
        setFrame(frame, display: true, animate: false)
    }
}
