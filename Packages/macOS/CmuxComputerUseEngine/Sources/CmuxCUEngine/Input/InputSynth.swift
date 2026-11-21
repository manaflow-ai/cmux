// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import CoreGraphics
import Foundation

enum PointerButton: String, Sendable {
    case left, right, middle

    var cg: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var down: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var up: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    var dragged: CGEventType {
        switch self {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
    }
}

/// Input posted to one process (`CGEvent.postToPid`), never to the HID
/// stream: the person's cursor and keyboard focus stay where they are, and
/// the event reaches only the target app. A private event source keeps the
/// person's held modifiers out of agent events.
struct InputSynth: @unchecked Sendable {
    private let source = CGEventSource(stateID: .privateState)
    /// Unicode is typed in chunks the event field accepts.
    static let typingChunk = 20

    func click(at point: CGPoint, pid: pid_t, windowNumber: CGWindowID?, button: PointerButton = .left, count: Int = 1,
               flags: CGEventFlags = []) {
        for click in 1...max(1, count) {
            for type in [button.down, button.up] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                          mouseButton: button.cg) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.flags = flags
                target(event, windowNumber)
                event.postToPid(pid)
            }
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, pid: pid_t, windowNumber: CGWindowID?, steps: Int = 12) {
        let button = PointerButton.left
        post(button.down, at: start, pid: pid, windowNumber: windowNumber)
        for step in 1...max(1, steps) {
            let t = CGFloat(step) / CGFloat(max(1, steps))
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(button.dragged, at: point, pid: pid, windowNumber: windowNumber)
        }
        post(button.up, at: end, pid: pid, windowNumber: windowNumber)
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, pid: pid_t, windowNumber: CGWindowID?) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.location = point
        target(event, windowNumber)
        event.postToPid(pid)
    }

    func key(_ spec: KeySpec, pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: spec.keyCode, keyDown: down) else { continue }
            event.flags = spec.flags
            event.postToPid(pid)
        }
    }

    func type(_ text: String, pid: pid_t) {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(units.count, start + Self.typingChunk)
            // Never split a surrogate pair across two events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.postToPid(pid)
            }
            start = end
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, pid: pid_t, windowNumber: CGWindowID?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        target(event, windowNumber)
        event.postToPid(pid)
    }

    /// Names the window under the pointer so AppKit routes a background
    /// event to it without the window being key or the app frontmost.
    private func target(_ event: CGEvent, _ windowNumber: CGWindowID?) {
        guard let windowNumber else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
    }
}
