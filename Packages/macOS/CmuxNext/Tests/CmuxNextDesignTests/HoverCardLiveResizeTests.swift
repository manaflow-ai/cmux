import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A live resize posts the window's resize at each step, and the hover-card coordinator found that window among every
/// source's window (each tab cell, sidebar row and toolbar that shows cards) before it saw that a live resize waits
/// for its end (`geometryChanged`): 12 of 381 main-thread samples of a corner drag's steps in the user's grid (other
/// Mac, 2026-11-24, `chaos_resize`). A step of a live resize reads no source.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardLiveResizeTests {
    private final class Source: HoverCardSource {
        let window: NSWindow
        var reads = 0
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? {
            reads += 1
            return window
        }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    @Test func aLiveResizeStepReadsNoSourceWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.pointerLocation = { CGPoint(x: window.frame.midX, y: window.frame.midY) }
        let sources = (0..<40).map { _ in Source(window: window) }
        for source in sources { coordinator.register(source) }
        defer { for source in sources { coordinator.unregister(source) } }

        // The window enters a live resize through AppKit's notification, posted to a private center's tracker.
        let center = NotificationCenter()
        let app = LiveResizeWindows.shared
        LiveResizeWindows.shared = LiveResizeWindows(center: center)
        defer { LiveResizeWindows.shared = app }
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        try #require(Motion.isLiveResizing(window), "fixture: the window is not in a live resize")

        for source in sources { source.reads = 0 }
        for step in 1...10 { // AppKit posts each step's resize
            window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: 400 + 4 * step, height: 300 + 2 * step)),
                            display: false)
        }
        let reads = sources.reduce(0) { $0 + $1.reads }
        #expect(reads == 0, "\(reads) reads of a source's window in 10 steps of a live resize")
    }
}
