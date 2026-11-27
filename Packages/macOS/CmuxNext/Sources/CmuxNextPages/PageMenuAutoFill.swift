public import AppKit

/// Keeps macOS's AutoFill out of a first-party page's context menu. With a text field focused (the
/// agent composer), AppKit asks the view for its text input context between the right-click and
/// `willOpenMenu`, and adds AutoFill when it gets one. The item is not in the menu the page edits,
/// so the view answers no input context from the right-click until the menu closes; a page is app
/// chrome with nothing to fill. A right-click that opens no native menu (the page draws its own)
/// ends the window after `window` seconds, so typing never loses its input context for long.
@MainActor
public final class PageMenuAutoFill {
    private var rightClickAt: TimeInterval?
    private var menuOpen = false
    private let window: TimeInterval

    nonisolated public init(window: TimeInterval = 1.5) {
        self.window = window
    }

    /// Call on a right mouse down, and on a Control-click (also a context click).
    public func noteContextClick(_ event: NSEvent) {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return }
        rightClickAt = ProcessInfo.processInfo.systemUptime
    }

    /// Call from `willOpenMenu`.
    public func menuWillOpen() { menuOpen = true }

    /// Call from `didCloseMenu`.
    public func menuDidClose() {
        menuOpen = false
        rightClickAt = nil
    }

    /// Whether the view answers no input context now.
    public func hidesInputContext(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        menuOpen || rightClickAt.map { now - $0 < window } == true
    }
}
