#if DEBUG
internal import Foundation

/// An AppKit-free twin of the recognized event-type tokens accepted by the
/// v1-only `overlay_hit_gate` / `portal_hit_gate` drag-overlay gate commands.
///
/// The legacy `TerminalController` bodies parsed a lowercased token straight to
/// an `NSEvent.EventType?` (with `none` resolving to a known `nil`). That parse
/// fused the *recognition* decision (is this token one of the gate's accepted
/// names?) with an AppKit type the control-plane package cannot host. This enum
/// carries only the recognition half: the coordinator parses a raw token into a
/// case (or `nil` for an unrecognized token, reproducing the legacy
/// `(isKnown: false)` branch) and owns the usage/unknown `ERROR` strings and the
/// `"true"`/`"false"` formatting, while the narrowed ``ControlDebugContext``
/// witness maps the case to the matching `NSEvent.EventType?` app-side and reads
/// the live `DragOverlayRoutingPolicy` against the drag pasteboard.
public enum ControlDebugOverlayEventToken: Sendable, Equatable, CaseIterable {
    case leftMouseDragged
    case rightMouseDragged
    case otherMouseDragged
    case mouseMoved
    case mouseEntered
    case mouseExited
    case flagsChanged
    case cursorUpdate
    case appKitDefined
    case systemDefined
    case applicationDefined
    case periodic
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case otherMouseDown
    case otherMouseUp
    case scrollWheel
    /// The `none` token, which the legacy parse resolved to a known `nil`
    /// `NSEvent.EventType`.
    case none

    /// Parses an already-trimmed, lowercased gate token into the recognized
    /// case, or `nil` for an unrecognized token (the legacy `(isKnown: false)`
    /// branch). The accepted spellings are byte-faithful to the legacy
    /// `TerminalController.parseOverlayEventType(_:)` switch, including the
    /// `mousemove` alias for `mouseMoved`.
    ///
    /// - Parameter token: The trimmed, lowercased event-type token.
    /// - Returns: The recognized case, or `nil` when the token is unknown.
    public init?(lowercasedToken token: String) {
        switch token {
        case "leftmousedragged": self = .leftMouseDragged
        case "rightmousedragged": self = .rightMouseDragged
        case "othermousedragged": self = .otherMouseDragged
        case "mousemove", "mousemoved": self = .mouseMoved
        case "mouseentered": self = .mouseEntered
        case "mouseexited": self = .mouseExited
        case "flagschanged": self = .flagsChanged
        case "cursorupdate": self = .cursorUpdate
        case "appkitdefined": self = .appKitDefined
        case "systemdefined": self = .systemDefined
        case "applicationdefined": self = .applicationDefined
        case "periodic": self = .periodic
        case "leftmousedown": self = .leftMouseDown
        case "leftmouseup": self = .leftMouseUp
        case "rightmousedown": self = .rightMouseDown
        case "rightmouseup": self = .rightMouseUp
        case "othermousedown": self = .otherMouseDown
        case "othermouseup": self = .otherMouseUp
        case "scrollwheel": self = .scrollWheel
        case "none": self = .none
        default: return nil
        }
    }
}
#endif
