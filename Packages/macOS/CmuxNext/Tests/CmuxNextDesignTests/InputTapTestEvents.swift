import AppKit
import CmuxNextInput
import Testing

/// Events and one dispatch through an ``InputEventTap`` the way `CmuxApplication.sendEvent` runs it,
/// for the Design owners that subscribe to the tap.
@MainActor
struct InputTapTestEvents {
    let tap = InputEventTap()

    /// Delivers `event` through the tap's three stages in one dispatch scope; true when an intercept
    /// consumed it (AppKit would not have dispatched it).
    @discardableResult
    func dispatch(_ event: NSEvent) -> Bool {
        var consumed = false
        tap.dispatching {
            tap.deliverObserve(event)
            consumed = tap.deliverIntercepts(event) == .consume
            tap.deliverAfterDispatch(event)
        }
        return consumed
    }

    /// The live subscriptions of the tap, every class and stage.
    var subscriptions: Int {
        InputEventClass.allCases.reduce(0) { total, eventClass in
            total + tap.subscriberCount(eventClass, stage: .observe) + tap.subscriberCount(eventClass, stage: .intercept)
                + tap.subscriberCount(eventClass, stage: .afterDispatch)
        }
    }

    static func key(_ type: NSEvent.EventType = .keyDown, keyCode: UInt16 = 53, in window: NSWindow? = nil,
                    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                             windowNumber: window?.windowNumber ?? 0, context: nil,
                                             characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: keyCode))
    }

    static func mouse(_ type: NSEvent.EventType, at point: CGPoint = .zero, in window: NSWindow? = nil) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                               windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1))
    }

    /// A tracking-area edge: `.mouseEntered` or `.mouseExited`.
    static func tracking(_ type: NSEvent.EventType, in window: NSWindow? = nil) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                                                   windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                   trackingNumber: 0, userData: nil))
    }

    static func scroll() throws -> NSEvent {
        _ = NSApplication.shared
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// A borderless window on screen.
    static func window(_ frame: CGRect = CGRect(x: 200, y: 200, width: 400, height: 300)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}
