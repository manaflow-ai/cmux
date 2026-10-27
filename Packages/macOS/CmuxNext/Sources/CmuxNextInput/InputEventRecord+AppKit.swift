public import AppKit
public import CmuxNextInputCore

extension InputEventType {
    /// The type of an `NSEvent` the tap delivers; nil for the others (AppKit-defined, system-defined,
    /// periodic, cursor-update and tablet events).
    public init?(_ type: NSEvent.EventType) {
        switch type {
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        case .flagsChanged: self = .flagsChanged
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .rightMouseDown: self = .rightMouseDown
        case .rightMouseUp: self = .rightMouseUp
        case .otherMouseDown: self = .otherMouseDown
        case .otherMouseUp: self = .otherMouseUp
        case .mouseMoved: self = .mouseMoved
        case .leftMouseDragged: self = .leftMouseDragged
        case .rightMouseDragged: self = .rightMouseDragged
        case .otherMouseDragged: self = .otherMouseDragged
        case .scrollWheel: self = .scrollWheel
        case .magnify: self = .magnify
        case .rotate: self = .rotate
        case .swipe: self = .swipe
        case .smartMagnify: self = .smartMagnify
        case .pressure: self = .pressure
        case .mouseEntered: self = .mouseEntered
        case .mouseExited: self = .mouseExited
        default: return nil
        }
    }
}

extension InputEventRecord {
    /// The record of `event`, whose type is `type`. Reads only the fields that `event`'s type has
    /// (AppKit raises for a key code of a mouse event); allocates nothing.
    public init(_ event: NSEvent, type: InputEventType) {
        let window = event.window
        let location = event.locationInWindow
        let screen = window.map { $0.convertPoint(toScreen: location) } ?? location
        self.init(type: type, timestamp: event.timestamp,
                  windowNumber: window?.windowNumber ?? 0,
                  ownerWindowNumber: window.map { Self.ownerWindow(of: $0).windowNumber } ?? 0,
                  location: InputPoint(x: location.x, y: location.y),
                  screenLocation: InputPoint(x: screen.x, y: screen.y),
                  modifierFlags: InputModifierFlags(rawValue: event.modifierFlags.rawValue).intersection(.deviceIndependentMask))
        switch type.eventClass {
        case .key:
            keyCode = event.keyCode
            isRepeat = event.isARepeat
        case .flags:
            keyCode = event.keyCode
        case .button:
            buttonNumber = event.buttonNumber
            clickCount = event.clickCount
        case .drag:
            buttonNumber = event.buttonNumber
        case .scroll:
            scrollPhase = Self.scrollPhase(of: event)
            scrollDelta = InputPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
            hasPreciseScrollingDeltas = event.hasPreciseScrollingDeltas
        case .pointerMove, .gesture, .tracking:
            break
        }
    }

    /// The window that owns `window`'s events: itself, or the top of its parent chain below the first
    /// panel (a Chromium page window belongs to the cmux window that holds it; app panels stay their own).
    public static func ownerWindow(of window: NSWindow) -> NSWindow {
        var current = window
        while !(current is NSPanel), let parent = current.parent { current = parent }
        return current
    }

    /// Where a scroll event is in its gesture: momentum first, then the gesture phase.
    public static func scrollPhase(of event: NSEvent) -> InputScrollPhase {
        let momentum = event.momentumPhase
        if !momentum.isEmpty { return momentum.isDisjoint(with: [.ended, .cancelled]) ? .momentum : .momentumEnded }
        let phase = event.phase
        if phase.isEmpty { return .none }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.began) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .changed
    }
}
