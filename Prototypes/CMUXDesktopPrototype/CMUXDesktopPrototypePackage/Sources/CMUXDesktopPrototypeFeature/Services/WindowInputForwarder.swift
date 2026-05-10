import AppKit
import CoreGraphics

@MainActor
struct WindowInputForwarder {
    private let accessibilityController = AccessibilityWindowController()

    func forwardMouse(_ input: WindowMouseInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        _ = accessibilityController.raise(window)

        let point = screenPoint(for: input.normalizedPoint, in: window)
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType(for: input.phase, button: input.button),
            mouseCursorPosition: point,
            mouseButton: cgMouseButton(for: input.button)
        ) else {
            return .eventCreationFailed
        }

        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(input.clickCount, 1)))
        event.postToPid(window.ownerPID)
        return .succeeded
    }

    func forwardScroll(_ input: WindowScrollInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        _ = accessibilityController.raise(window)

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

        event.location = screenPoint(for: input.normalizedPoint, in: window)
        event.postToPid(window.ownerPID)
        return .succeeded
    }

    func forwardKey(_ input: WindowKeyInput, to window: HostWindow) -> WindowInputResult {
        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }

        _ = accessibilityController.raise(window)

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

        event.postToPid(window.ownerPID)
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

    private func cgMouseButton(for button: WindowMouseButton) -> CGMouseButton {
        switch button {
        case .left:
            return .left
        case .right:
            return .right
        case .other:
            return .center
        }
    }

    private func mouseType(for phase: WindowMousePhase, button: WindowMouseButton) -> CGEventType {
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
