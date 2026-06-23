public import AppKit

/// Repositions a window so it sits fully inside a target screen while preserving
/// its size, backing the `window.display` control command's move step.
///
/// Faithful lift of `AppDelegate.repositionPreservingSize(_:onto:)` from the
/// AppDelegate god file. The math is unchanged: the window's size is clamped to
/// the screen's `visibleFrame`, the window is centered on that visible area, the
/// origin is clamped so the whole frame stays inside it, and the resulting rect
/// is made `integral` before `setFrame(_:display:animate:)` is applied.
///
/// Deliberately does NOT raise, key, or activate the window: `window.display` is
/// not a focus-intent command, so it must never steal macOS focus.
///
/// A stateless value: it operates only on the `NSWindow`/`NSScreen` handed to
/// each call, so it is a `Sendable` struct rather than an actor. The method is
/// `@MainActor` because it mutates main-actor `NSWindow` state. Constructed (not
/// a static namespace), mirroring ``NewWindowCascadePlanner``.
public struct DisplayReposition: Sendable {
    /// Creates a window repositioner.
    public init() {}

    /// Repositions `window` so it sits fully inside `screen`, keeping its current
    /// size (clamped to the display) and centering it.
    ///
    /// Does not raise, key, or activate the window.
    ///
    /// - Parameters:
    ///   - window: The window to move.
    ///   - screen: The destination screen; the window is clamped to its
    ///     `visibleFrame`.
    @MainActor
    public func reposition(_ window: NSWindow, onto screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(window.frame.width, visible.width)
        let height = min(window.frame.height, visible.height)
        var origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height).integral
        window.setFrame(frame, display: true, animate: false)
    }
}
