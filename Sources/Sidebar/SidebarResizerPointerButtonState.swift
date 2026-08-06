import AppKit

/// Non-observed pointer-button state fed by the app's existing local event
/// monitor. Cursor release reads this state without synchronously querying
/// WindowServer from the main actor.
@MainActor
final class SidebarResizerPointerButtonState {
    private(set) var isLeftButtonDown = false

    func observe(_ eventType: NSEvent.EventType) {
        switch eventType {
        case .leftMouseDown:
            isLeftButtonDown = true
        case .leftMouseUp:
            isLeftButtonDown = false
        default:
            break
        }
    }

    func reset() {
        isLeftButtonDown = false
    }
}
