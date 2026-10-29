import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// An `.activeForHover` tracking area hears no exit while another app is active,
/// so cmux resigning active ends every hover it shows (a toast's hold included) and an enter while
/// inactive hovers nothing. A view in a panel that floats over another app (`.activeAlways`) keeps
/// hovering.
@MainActor @Suite(.serialized) struct HoverDeactivationTests {
    /// Runs `body` with the hover observer on a center of the test's own, in a launch that activates.
    private func withAppEvents(_ body: (NotificationCenter) throws -> Void) rethrows {
        _ = NSApplication.shared
        let savedNoActivate = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        let center = NotificationCenter()
        PointerHover.observe(AppEvents(center: center), keyWindow: { nil })
        defer {
            PointerHover.observe(nil)
            WindowPlacement.noActivate = savedNoActivate
        }
        try body(center)
    }

    private func shownWindow() -> NSWindow {
        let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: screen.maxX - 460, y: screen.minY + 60, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above the test host's other windows there, so the topmost check finds this one.
        window.level = .floating
        window.orderFrontRegardless()
        return window
    }

    private func enter(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    @Test func aDeactivationClearsAPointerHoverAndAnEnterWhileInactiveHoversNothing() throws {
        try withAppEvents { center in
            let window = shownWindow()
            defer { window.orderOut(nil) }
            let view = NSView(frame: CGRect(x: 100, y: 100, width: 80, height: 40))
            window.contentView?.addSubview(view)
            var changes: [Bool] = []
            let hover = PointerHover(view) { changes.append($0) }
            let inside = CGPoint(x: 140, y: 120)

            hover.mouseEntered(with: try enter(at: inside, in: window))
            #expect(hover.isHovering, "the enter's point is over the view")

            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            #expect(!hover.isHovering, "a hover stayed on after cmux resigned active (its area hears no exit then)")
            #expect(changes == [true, false], "the owner (a toast's hold) was not told the hover ended")
            #expect(!PointerHover.appShowsHover)

            hover.mouseEntered(with: try enter(at: inside, in: window))
            #expect(!hover.isHovering, "an .activeForHover target hovered while another app is active")

            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            hover.mouseEntered(with: try enter(at: inside, in: window))
            #expect(hover.isHovering, "hover did not come back once cmux is active again")
        }
    }

    @Test func aTargetOverAnotherAppKeepsHoveringWhileInactive() throws {
        try withAppEvents { center in
            let window = shownWindow()
            defer { window.orderOut(nil) }
            let view = NSView(frame: CGRect(x: 100, y: 100, width: 80, height: 40))
            window.contentView?.addSubview(view)
            let hover = PointerHover(view, hoversWhileInactive: true)
            #expect(view.trackingAreas.contains { $0.options.contains(.activeAlways) })

            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            hover.mouseEntered(with: try enter(at: CGPoint(x: 140, y: 120), in: window))
            #expect(hover.isHovering, "a panel over another app took no hover while cmux is inactive")
        }
    }

    @Test func aDeactivationEndsChromeHoverAndRevealHoverSetFromEnterAndExit() {
        withAppEvents { center in
            let chromeView = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            let chrome = ChromeHover(chromeView)
            let floatingView = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            let floating = ChromeHover(floatingView, tracking: .activeAlways)
            let region = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            let reveal = HoverReveal(region: region, tracksPointer: false)

            chrome.state.hovering = true
            floating.state.hovering = true
            reveal.setPointerInside(true)
            center.post(name: NSApplication.didResignActiveNotification, object: nil)

            #expect(!chrome.state.hovering, "a chrome hover stayed lit after cmux resigned active")
            #expect(floating.state.hovering, "an .activeAlways hover (a panel over another app) was cleared")
            #expect(!reveal.state.pointerInside, "a hover reveal stayed revealed after cmux resigned active")

            // Hover set again ends at the next deactivation too (the watch follows each hover).
            chrome.state.hovering = true
            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            #expect(!chrome.state.hovering)
        }
    }
}
