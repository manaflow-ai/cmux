#if DEBUG
import AppKit
import CmuxControlSocket

extension ControlDebugOverlayEventToken {
    /// Maps a recognized overlay-gate event token (the token recognition + the
    /// usage/unknown `ERROR` strings live in the `CmuxControlSocket`
    /// coordinator) to its `NSEvent.EventType`, with `.none` resolving to `nil`.
    /// This is the irreducible AppKit half the control-plane package cannot host,
    /// kept app-side as the conversion property on the token it derives from.
    var nsEventType: NSEvent.EventType? {
        switch self {
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDragged: return .rightMouseDragged
        case .otherMouseDragged: return .otherMouseDragged
        case .mouseMoved: return .mouseMoved
        case .mouseEntered: return .mouseEntered
        case .mouseExited: return .mouseExited
        case .flagsChanged: return .flagsChanged
        case .cursorUpdate: return .cursorUpdate
        case .appKitDefined: return .appKitDefined
        case .systemDefined: return .systemDefined
        case .applicationDefined: return .applicationDefined
        case .periodic: return .periodic
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .otherMouseDown: return .otherMouseDown
        case .otherMouseUp: return .otherMouseUp
        case .scrollWheel: return .scrollWheel
        case .none: return nil
        }
    }
}
#endif
