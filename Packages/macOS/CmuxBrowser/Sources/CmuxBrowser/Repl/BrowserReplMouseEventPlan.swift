public import AppKit

/// Mouse button named by the REPL driver protocol.
public enum BrowserReplMouseButton: String, Sendable, CaseIterable {
    case left
    case right
    case middle

    /// AppKit button number (`0` left, `1` right, `2` middle).
    public var buttonNumber: Int {
        switch self {
        case .left: 0
        case .right: 1
        case .middle: 2
        }
    }
}

/// Tracks pressed buttons for one tab and resolves each driver `input.mouse`
/// call into the AppKit event type WebKit expects.
///
/// Playwright models mouse state across calls: a `move` while a button is
/// down is a drag, and `clickCount` rises with repeated clicks. AppKit encodes
/// both in the event, so the state lives here rather than in the page.
public struct BrowserReplMouseState: Sendable, Equatable {
    /// Buttons currently held, in press order.
    public private(set) var pressedButtons: [BrowserReplMouseButton] = []

    public init() {}

    /// The AppKit event type for one driver call, updating held buttons.
    /// - Returns: `nil` for an unknown `type` or a `wheel` (sent as a CGEvent).
    public mutating func eventType(
        forType type: String,
        button: BrowserReplMouseButton
    ) -> NSEvent.EventType? {
        switch type {
        case "down":
            if !pressedButtons.contains(button) { pressedButtons.append(button) }
            switch button {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        case "up":
            pressedButtons.removeAll { $0 == button }
            switch button {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        case "move":
            switch pressedButtons.first {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            case .middle: return .otherMouseDragged
            case nil: return .mouseMoved
            }
        default:
            return nil
        }
    }

    /// Releases every held button, for tab close or session reset.
    public mutating func reset() {
        pressedButtons.removeAll()
    }
}

/// Coordinate conversion between the driver's CSS pixels and AppKit view points.
extension CGPoint {
    /// Converts this CSS-pixel point (top-left origin of the viewport) into the
    /// web view's own coordinate space.
    /// - Parameters:
    ///   - cssPerPoint: CSS pixels per view point (`1 / (pageZoom * magnification)`).
    ///   - viewIsFlipped: Whether the view's y axis grows downward.
    ///   - viewHeight: The view's bounds height in points.
    public func browserReplViewPoint(
        cssPerPoint: CGFloat,
        viewIsFlipped: Bool,
        viewHeight: CGFloat
    ) -> CGPoint {
        let scale = cssPerPoint > 0 ? cssPerPoint : 1
        let x = self.x / scale
        let y = self.y / scale
        return CGPoint(x: x, y: viewIsFlipped ? y : viewHeight - y)
    }
}
