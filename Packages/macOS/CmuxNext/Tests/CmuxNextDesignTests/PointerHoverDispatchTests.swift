import AppKit
@testable import CmuxNextDesign
import Testing

/// cx-2mp6: AppKit delivers a tracking area's enter and exit to its owner by
/// the Objective-C selectors `mouseEntered:` and `mouseExited:`. A
/// `PointerHover` owns its area, so it must answer those exact selectors; an
/// owner that does not dies with NSInvalidArgumentException in
/// `-[NSTrackingArea _dispatchMouseEntered:]` (seen after a sidebar row was
/// rebuilt and a context menu closed over it). These tests send the events the
/// way AppKit does, through the runtime, never through the Swift method.
@MainActor @Suite(.serialized)
struct PointerHoverDispatchTests {
    static let entered = #selector(NSResponder.mouseEntered(with:))
    static let exited = #selector(NSResponder.mouseExited(with:))

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            trackingNumber: 0, userData: nil))
    }

    /// Sends `selector` to every tracking-area owner of `view` the way
    /// `_NSTrackingAreaAKManager` does. An owner that does not answer is
    /// recorded as a failure instead of raising (which would end the run).
    static func dispatch(_ selector: Selector, _ event: NSEvent, to view: NSView) {
        for area in view.trackingAreas {
            guard let owner = area.owner as? NSObject else {
                Issue.record("a tracking area owner must be an Objective-C object")
                continue
            }
            let answers = owner.responds(to: selector)
            let name = NSStringFromClass(Swift.type(of: owner))
            #expect(answers, "\(name) must answer \(NSStringFromSelector(selector)) for its tracking area")
            if answers { _ = owner.perform(selector, with: event) }
        }
    }

    @Test func theOwnerAnswersAppKitsEnterAndExitSelectors() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let hover = PointerHover(view)
        let owners = view.trackingAreas.compactMap { $0.owner as? PointerHover }
        #expect(owners.count == 1 && owners.first === hover)
        #expect(hover.responds(to: Self.entered))
        #expect(hover.responds(to: Self.exited))
    }

    /// A row view is rebuilt (the icon chip appears): the old view leaves the
    /// window with its hover released, a new view and hover take its place,
    /// then AppKit dispatches the enter and the exit the pointer caused.
    @Test func aRebuiltRowTakesAnEnterAndAnExitThroughTheRuntime() throws {
        let window = Self.window()
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        let content = try #require(window.contentView)
        let frame = NSRect(x: 20, y: 20, width: 200, height: 30)
        let point = NSPoint(x: frame.midX, y: frame.midY)

        let oldRow = NSView(frame: frame)
        content.addSubview(oldRow)
        var oldHover: PointerHover? = PointerHover(oldRow)
        #expect(oldHover != nil)

        // The rebuild.
        oldRow.removeFromSuperview()
        oldHover = nil
        #expect(oldRow.trackingAreas.allSatisfy { !($0.owner is PointerHover) },
                "a released hover takes its tracking area with it")
        let newRow = NSView(frame: frame)
        content.addSubview(newRow)
        let newHover = PointerHover(newRow)

        PointerHover.setDebugPointer(point, in: window)
        Self.dispatch(Self.entered, try Self.event(.mouseEntered, at: point, in: window), to: newRow)
        #expect(newHover.isHovering)

        PointerHover.setDebugPointer(nil, in: window)
        Self.dispatch(Self.exited, try Self.event(.mouseExited, at: point, in: window), to: newRow)
        #expect(!newHover.isHovering)
    }
}
