public import AppKit
public import CmuxNextActions

/// AppKit's input event as the registry reads it (``ActionInputEvent``): a key, a click or neither.
nonisolated extension NSEvent: ActionInputEvent {
    public var actionInputKind: ActionInputKind? {
        switch type {
        case .keyDown, .keyUp: .key
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: .pointer
        default: nil
        }
    }
}
