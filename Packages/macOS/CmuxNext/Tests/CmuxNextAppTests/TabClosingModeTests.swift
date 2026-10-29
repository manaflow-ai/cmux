import AppKit
@testable import CmuxNextInput
@testable import CmuxNextTabs
import Testing

/// Closing mode's exit watch on the app's input tap: once the pointer leaves the strip
/// in closing mode the watch hears moves in the strip's window, presses in every window of the app
/// and other apps' events through `globalObserve`; a press outside the strip ends closing mode, and
/// every end path gives the tap back all three subscriptions.
@MainActor @Suite(.serialized) struct TabClosingModeTests {
    @MainActor final class Harness {
        let tap = InputEventTap()
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 200, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)

        init() {
            let model = TabStripModel(tabs: (0..<4).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
            strip = TabStripView(model: model, input: tap)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            for window in [window, other] {
                window.isReleasedWhenClosed = false
                window.orderFrontRegardless()
            }
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
        }

        func close() { for window in [window, other] { window.orderOut(nil) } }

        /// Closing mode as a mouse close leaves it, with the pointer gone from the strip.
        func enterClosingModeAndLeave() {
            strip.closingModeWidth = 120
            strip.closingWatch.pointerLeft()
        }

        func press(in target: NSWindow) throws {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        var moves: Int { tap.subscriberCount(.pointerMove, stage: .observe) }
        var presses: Int { tap.subscriberCount(.button, stage: .observe) }
    }

    @Test func leavingTheStripInClosingModeSubscribesMovesPressesAndOtherApps() throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.moves == 0 && harness.presses == 0 && harness.tap.globalMonitorCount == 0, "no watch before closing mode")

        harness.enterClosingModeAndLeave()
        #expect(harness.strip.closingWatch.isFollowingPointer)
        #expect(harness.moves == 1)
        #expect(harness.presses == 1)
        #expect(harness.tap.globalMonitorCount == 1, "other apps' moves and presses go through the tap's globalObserve")

        harness.strip.closingWatch.pointerLeft()
        #expect(harness.moves == 1 && harness.presses == 1 && harness.tap.globalMonitorCount == 1, "leaving again subscribes nothing more")
    }

    @Test func aPressInAnotherWindowOfTheAppEndsClosingModeAndUnsubscribes() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.enterClosingModeAndLeave()

        try harness.press(in: harness.other)
        #expect(harness.strip.closingModeWidth == nil, "a press outside the strip ends closing mode")
        #expect(!harness.strip.closingWatch.isFollowingPointer)
        #expect(harness.moves == 0)
        #expect(harness.presses == 0)
        try harness.press(in: harness.other)
        #expect(harness.tap.globalMonitorCount == 0, "the tap removes the cancelled global monitor at its next delivery")
    }

    @Test func theStripLeavingItsWindowEndsTheWatch() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.enterClosingModeAndLeave()

        harness.window.contentView = nil
        #expect(harness.strip.closingModeWidth == nil)
        #expect(!harness.strip.closingWatch.isFollowingPointer)
        #expect(harness.moves == 0 && harness.presses == 0)
    }

    @Test func theWatchActsOnLeftAndRightPressesOnly() {
        #expect(TabClosingModeWatch.endsOnPress(.leftMouseDown))
        #expect(TabClosingModeWatch.endsOnPress(.rightMouseDown))
        #expect(!TabClosingModeWatch.endsOnPress(.otherMouseDown))
        #expect(!TabClosingModeWatch.endsOnPress(.leftMouseUp))
    }
}
