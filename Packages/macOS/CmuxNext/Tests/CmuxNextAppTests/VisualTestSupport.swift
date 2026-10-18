import AppKit
@testable import CmuxNextDesign

/// Preconditions for tests whose assertions describe an onscreen AppKit pass.
@MainActor enum VisualTestSupport {
    /// A display that can actually host and draw a test window. `NSScreen.screens` can be
    /// populated on a hosted runner even when a newly created window has no screen.
    static func hasVisibleDisplay() -> Bool {
        guard let screen = NSScreen.screens.first, !DisplaySleep.shared.isAsleep(screen) else { return false }
        _ = NSApplication.shared
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40,
                           width: 240, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        return window.screen != nil
    }

    /// A visible display where AppKit animations advance instead of snapping at once.
    static func hasAnimatableDisplay() -> Bool {
        guard let screen = NSScreen.screens.first, !DisplaySleep.shared.isAsleep(screen), Motion.speed != .off else {
            return false
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40,
                                                   width: 240, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        return window.screen != nil && Motion.canAnimate(in: window.contentView)
    }

    static func hasSurfaceDisplay() -> Bool {
        hasVisibleDisplay() && !ReduceTransparency.shared.isEnabled
    }
}
