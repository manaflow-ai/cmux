import AppKit
import CoreGraphics
import Darwin

@MainActor
struct WindowInputForwarder {
    private let accessibilityController = AccessibilityWindowController()

    func forwardMouse(_ input: WindowMouseInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        let point = screenPoint(for: input.normalizedPoint, in: window)
        let clickCount = max(input.clickCount, 1)
        guard let event = mouseEvent(
            type: nsMouseType(for: input.phase, button: input.button),
            location: point,
            button: input.button,
            clickCount: clickCount,
            window: window
        ) else {
            return .eventCreationFailed
        }

        stamp(event, screenPoint: point, window: window, button: input.button, clickCount: clickCount)
        postCursorNeutralMouseEvent(event, to: window.ownerPID)
        return .succeeded
    }

    func forwardScroll(_ input: WindowScrollInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(input.deltaY),
            wheel2: Int32(input.deltaX),
            wheel3: 0
        ) else {
            return .eventCreationFailed
        }

        let point = screenPoint(for: input.normalizedPoint, in: window)
        event.location = point
        SkyLightEventPost.setWindowLocation(event, windowLocalPoint(for: point, in: window))
        postCursorNeutralMouseEvent(event, to: window.ownerPID)
        return .succeeded
    }

    func forwardKey(_ input: WindowKeyInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: CGKeyCode(input.keyCode),
            keyDown: input.isDown
        ) else {
            return .eventCreationFailed
        }

        event.flags = cgFlags(for: input.modifierFlags)
        if input.isDown, let characters = input.characters, !characters.isEmpty {
            let utf16 = Array(characters.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }

        if !SkyLightEventPost.postToPid(window.ownerPID, event: event, attachAuthMessage: true) {
            event.postToPid(window.ownerPID)
        }
        return .succeeded
    }

    private var eventSource: CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func screenPoint(for normalizedPoint: CGPoint, in window: HostWindow) -> CGPoint {
        CGPoint(
            x: window.frame.minX + normalizedPoint.x * window.frame.width,
            y: window.frame.minY + normalizedPoint.y * window.frame.height
        )
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location point: CGPoint,
        button: WindowMouseButton,
        clickCount: Int,
        window: HostWindow
    ) -> CGEvent? {
        let pressure: Float = switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            1
        default:
            0
        }

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: cocoaLocation(fromScreenPoint: point),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: Int(window.id),
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: pressure
        )?.cgEvent else {
            return nil
        }

        return event
    }

    private func stamp(
        _ event: CGEvent,
        screenPoint: CGPoint,
        window: HostWindow,
        button: WindowMouseButton,
        clickCount: Int
    ) {
        event.location = screenPoint
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(mouseButtonNumber(for: button)))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
        SkyLightEventPost.setWindowLocation(event, windowLocalPoint(for: screenPoint, in: window))
        SkyLightEventPost.setIntegerField(event, field: 40, value: Int64(window.ownerPID))
    }

    private func postCursorNeutralMouseEvent(_ event: CGEvent, to pid: pid_t) {
        _ = SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: false)
        event.postToPid(pid)
    }

    private func windowLocalPoint(for point: CGPoint, in window: HostWindow) -> CGPoint {
        CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
    }

    private func cocoaLocation(fromScreenPoint point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.height ?? point.y
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }

    private func mouseButtonNumber(for button: WindowMouseButton) -> Int {
        switch button {
        case .left:
            return 0
        case .right:
            return 1
        case .other(let buttonNumber):
            return buttonNumber
        }
    }

    private func nsMouseType(for phase: WindowMousePhase, button: WindowMouseButton) -> NSEvent.EventType {
        switch (phase, button) {
        case (.down, .left):
            return .leftMouseDown
        case (.dragged, .left):
            return .leftMouseDragged
        case (.up, .left):
            return .leftMouseUp
        case (.down, .right):
            return .rightMouseDown
        case (.dragged, .right):
            return .rightMouseDragged
        case (.up, .right):
            return .rightMouseUp
        case (.down, .other):
            return .otherMouseDown
        case (.dragged, .other):
            return .otherMouseDragged
        case (.up, .other):
            return .otherMouseUp
        case (.moved, _):
            return .mouseMoved
        }
    }

    private func cgFlags(for flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) {
            cgFlags.insert(.maskCommand)
        }
        if flags.contains(.option) {
            cgFlags.insert(.maskAlternate)
        }
        if flags.contains(.control) {
            cgFlags.insert(.maskControl)
        }
        if flags.contains(.shift) {
            cgFlags.insert(.maskShift)
        }
        if flags.contains(.capsLock) {
            cgFlags.insert(.maskAlphaShift)
        }
        if flags.contains(.function) {
            cgFlags.insert(.maskSecondaryFn)
        }
        return cgFlags
    }
}
