import AppKit
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

/// A tab strip mounts the capture as a `.background` of a view with its own tap gesture, so
/// the click may never be hit-tested down to the capture view. These tests cover the path that
/// does not depend on hit-testing.
@MainActor
@Suite struct MiddleClickCaptureMonitorTests {
    private func makeWindow(capture view: MiddleClickCaptureView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        view.frame = NSRect(x: 20, y: 10, width: 120, height: 30)
        container.addSubview(view)
        window.contentView = container
        return window
    }

    @Test func middlePressInsideBoundsInvokesHandlerAndIsConsumed() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)

        let consumed = view.handleMiddleMouseDown(
            buttonNumber: 2,
            window: window,
            locationInWindow: NSPoint(x: 60, y: 25)
        )

        #expect(consumed)
        #expect(invoked == 1)
    }

    @Test func middlePressOutsideBoundsIsIgnored() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)

        let consumed = view.handleMiddleMouseDown(
            buttonNumber: 2,
            window: window,
            locationInWindow: NSPoint(x: 180, y: 25)
        )

        #expect(!consumed)
        #expect(invoked == 0)
    }

    @Test func nonMiddleButtonIsIgnored() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)

        for button in [0, 1, 3, 4] {
            let consumed = view.handleMiddleMouseDown(
                buttonNumber: button,
                window: window,
                locationInWindow: NSPoint(x: 60, y: 25)
            )
            #expect(!consumed)
        }
        #expect(invoked == 0)
    }

    @Test func pressInAnotherWindowIsIgnored() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        _ = makeWindow(capture: view)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let consumed = view.handleMiddleMouseDown(
            buttonNumber: 2,
            window: other,
            locationInWindow: NSPoint(x: 60, y: 25)
        )

        #expect(!consumed)
        #expect(invoked == 0)
    }

    @Test func hiddenViewIgnoresMiddlePress() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)
        view.isHidden = true

        let consumed = view.handleMiddleMouseDown(
            buttonNumber: 2,
            window: window,
            locationInWindow: NSPoint(x: 60, y: 25)
        )

        #expect(!consumed)
        #expect(invoked == 0)
    }

    @Test func pressClippedByAnAncestorIsIgnored() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)
        // Shrink the parent so the right half of the capture view is clipped away.
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 80, height: 60)

        let consumed = view.handleMiddleMouseDown(
            buttonNumber: 2,
            window: window,
            locationInWindow: NSPoint(x: 120, y: 25)
        )

        #expect(!consumed)
        #expect(invoked == 0)
    }

    // MARK: Delivery through the registered monitor

    /// Builds a real middle-button `otherMouseDown` aimed at `locationInWindow` of `window`.
    private func middleMouseDown(in window: NSWindow, at locationInWindow: NSPoint) throws -> NSEvent {
        let screenHeight = try #require(NSScreen.screens.first?.frame.height)
        let screenPoint = window.convertPoint(toScreen: locationInWindow)
        let cgEvent = try #require(CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y),
            mouseButton: .center
        ))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        try #require(event.buttonNumber == 2)
        return event
    }

    @Test func monitorRegisteredInWindowFiresForMiddlePressAndStopsAfterRemoval() throws {
        _ = NSApplication.shared
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }
        let window = makeWindow(capture: view)
        window.orderBack(nil)
        defer { window.close() }
        try #require(window.windowNumber > 0)

        // Inside the view: the monitor runs `onMiddleClick` once for a real event.
        NSApp.sendEvent(try middleMouseDown(in: window, at: NSPoint(x: 60, y: 25)))
        #expect(invoked == 1)

        // Outside the view: the monitor lets the event through untouched.
        NSApp.sendEvent(try middleMouseDown(in: window, at: NSPoint(x: 180, y: 25)))
        #expect(invoked == 1)

        // Once the view leaves its window the monitor is gone.
        view.removeFromSuperview()
        NSApp.sendEvent(try middleMouseDown(in: window, at: NSPoint(x: 60, y: 25)))
        #expect(invoked == 1)
    }
}
