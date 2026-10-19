import AppKit
import GhosttyKit

extension GhosttyMouseSessionLedger {
    /// A button whose native press is owned by a terminal surface session.
    enum Button: String, CaseIterable, Hashable, Sendable {
        case left
        case right
        case middle

        /// Creates a tracked button for a mouse-up event, if the event is one
        /// of the buttons forwarded to Ghostty.
        init?(mouseUpEvent: NSEvent) {
            switch mouseUpEvent.type {
            case .leftMouseUp:
                self = .left
            case .rightMouseUp:
                self = .right
            case .otherMouseUp:
                guard mouseUpEvent.buttonNumber == 2 else { return nil }
                self = .middle
            default:
                return nil
            }
        }

        /// The corresponding libghostty button value.
        var ghosttyButton: ghostty_input_mouse_button_e {
            switch self {
            case .left:
                return GHOSTTY_MOUSE_LEFT
            case .right:
                return GHOSTTY_MOUSE_RIGHT
            case .middle:
                return GHOSTTY_MOUSE_MIDDLE
            }
        }

        /// The AppKit bit used when reconciling an event-stream gap.
        var pressedMouseButtonsMask: Int {
            switch self {
            case .left:
                return 1 << 0
            case .right:
                return 1 << 1
            case .middle:
                return 1 << 2
            }
        }

        var ordering: Int {
            switch self {
            case .left: return 0
            case .right: return 1
            case .middle: return 2
            }
        }
    }
}
