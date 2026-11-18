import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?" (audit section 16). A
/// window showing a page kept the overlay above it by re-reading its child windows after every event, twice (the
/// overlay layer's check and its host's), whether or not any window had come, gone or moved. The order is checked
/// when it can have changed: a child added, removed, shown, hidden or made key, or the window itself shown or moved.
@MainActor @Suite(.serialized, .closesItsWindows) struct OverlayOrderCheckTests {
    private func window() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        return window
    }

    private func page() -> NSWindow {
        let page = NSWindow(contentRect: CGRect(x: 220, y: 220, width: 400, height: 300), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    /// An event cycle of `window` as AppKit ends it: `didUpdate` on the default center, the one AppKit posts it to and
    /// the overlay observes.
    private func update(_ window: NSWindow, times: Int = 1) {
        for _ in 0..<times {
            // global-notice-allow: AppKit posts NSWindow.didUpdateNotification to the default center; the overlay layer and host observe it there
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        }
    }

    /// Detector: 1,000 event cycles that change no window run no placement or order check (they ran 2,000).
    @Test func eventsThatMoveNoWindowCheckNoChildOrder() throws {
        let window = window()
        defer { window.close() }
        let pages = (0..<6).map { _ in page() }
        for page in pages { window.addChildWindow(page, ordered: .above) }
        defer { for page in pages { window.removeChildWindow(page); page.close() } }
        window.overlayLayer.evaluate()
        #expect(window.overlayLayer.placement == .overlayWindow)
        let host = try #require(WindowOverlayHost.existingHost(for: window))
        update(window) // the setup's own changes are checked once
        #expect(window.overlayLayer.isOverlayAboveContent)
        // Both checks end in the host's order check: the layer's evaluate reasserts the order through it.
        let checks = host.orderChecks
        let events = 1_000
        let started = ContinuousClock.now
        update(window, times: events)
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let ran = host.orderChecks - checks
        print("overlay-order-bench pages=6 events=\(events) order_checks=\(ran) total_ms=\(String(format: "%.2f", milliseconds))")
        #expect(ran == 0, "the child window order was checked \(ran) times for \(events) events that moved nothing")
        #expect(window.overlayLayer.isOverlayAboveContent)
    }

    /// A page added later still goes under the overlay, and the last page's removal takes the overlay back into the
    /// window at the next event.
    @Test func aPageAddedOrRemovedStillMovesTheOverlay() throws {
        let window = window()
        defer { window.close() }
        let first = page()
        window.addChildWindow(first, ordered: .above)
        defer { first.close() }
        update(window)
        #expect(window.overlayLayer.placement == .overlayWindow)
        let second = page()
        defer { second.close() }
        window.addChildWindow(second, ordered: .above)
        update(window)
        #expect(window.overlayLayer.isOverlayAboveContent, "a page added above the overlay goes back under it")
        window.removeChildWindow(second)
        window.removeChildWindow(first)
        update(window)
        #expect(window.overlayLayer.placement == .inWindow, "with no page left, the overlay comes back into the window")
    }
}
