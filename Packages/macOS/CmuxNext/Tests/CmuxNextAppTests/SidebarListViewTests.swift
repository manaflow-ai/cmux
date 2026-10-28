import AppKit
import CmuxNextInput
@testable import CmuxNextSidebar
import Testing

/// The list's pointer-end watch on the app's input tap: while the list is in a window it holds one
/// press observer and one release after-dispatch observer, both every window and both asked only while it holds a
/// gesture; a press anywhere ends a press whose release never came; leaving the window gives both back.
/// Uses `SidebarPointerGestureTests`' list: loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`).
@MainActor @Suite(.serialized) struct SidebarListViewTests {
    typealias G = SidebarPointerGestureTests

    static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    static func mouse(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    static func otherWindow() -> NSWindow {
        let other = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 200, height: 200), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        return other
    }

    @Test func aListInAWindowHoldsOnePressAndOneReleaseSubscriptionAndGivesThemBackWhenItLeaves() {
        let (list, window) = G.list()
        defer { window.close() }
        let tap = InputEventTap()
        #expect(tap.subscriberCount(.button, stage: .observe) == 0)
        list.inputTap = tap
        #expect(tap.subscriberCount(.button, stage: .observe) == 1)
        #expect(tap.subscriberCount(.button, stage: .afterDispatch) == 1)
        #expect(tap.subscriberCount(.button, stage: .intercept) == 0, "the list never stops a press or a release")
        list.removeFromSuperview()
        #expect(tap.subscriberCount(.button, stage: .observe) == 0, "a list out of a window still hears presses")
        #expect(tap.subscriberCount(.button, stage: .afterDispatch) == 0)
    }

    @Test func thePressOfAnotherWindowEndsAHeldDragWhoseReleaseNeverCame() throws {
        let (list, window) = G.list()
        defer { window.close() }
        let tap = InputEventTap()
        list.inputTap = tap
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 40)], release: false)
        #expect(list.drag != nil)
        let other = Self.otherWindow()
        defer { other.close() }
        Self.dispatch(try Self.mouse(.leftMouseDown, in: other), through: tap)
        #expect(list.drag == nil && list.press == nil, "the app's next press left the drag alive")
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(G.ids(list) == order, "the lost drag dropped: \(G.ids(list))")
    }

    @Test func aReleaseInTheListsOwnWindowLeavesTheDragToMouseUp() throws {
        let (list, window) = G.list()
        defer { window.close() }
        let tap = InputEventTap()
        list.inputTap = tap
        list.leftButtonIsDown = { false }
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 60)], release: false)
        let drag = try #require(list.drag)
        Self.dispatch(try Self.mouse(.leftMouseUp, in: window), through: tap)
        #expect(list.drag === drag, "the tap ended a drag whose release came to the list's own window")
    }

    @Test func aReplacedTapGetsTheSubscriptionsAndTheOldOneNone() {
        let (list, window) = G.list()
        defer { window.close() }
        let first = InputEventTap(), second = InputEventTap()
        list.inputTap = first
        list.inputTap = second
        #expect(first.subscriberCount(.button, stage: .observe) == 0 && first.subscriberCount(.button, stage: .afterDispatch) == 0)
        #expect(second.subscriberCount(.button, stage: .observe) == 1 && second.subscriberCount(.button, stage: .afterDispatch) == 1)
    }
}
