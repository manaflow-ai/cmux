public import AppKit

/// The AppKit event types for a driver `input.mouse` call, with the buttons
/// held across calls: a move while a button is down is a drag, as WebKit
/// expects for selections and HTML5 drag starts.
public nonisolated struct MouseEventPlan: Sendable {
    public nonisolated enum Button: String, Hashable, Sendable {
        case left, right, middle
    }

    public private(set) var held: Set<Button> = []

    public init() {}

    /// The event type for one call; `nil` for a wheel (a scroll event) or an
    /// unknown type. Updates the held buttons.
    public mutating func eventType(for type: String, button: Button) -> NSEvent.EventType? {
        switch type {
        case "move":
            if held.contains(.left) { return .leftMouseDragged }
            if held.contains(.right) { return .rightMouseDragged }
            if held.contains(.middle) { return .otherMouseDragged }
            return .mouseMoved
        case "down":
            held.insert(button)
            switch button {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        case "up":
            held.remove(button)
            switch button {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        default:
            return nil
        }
    }

    /// CSS pixels from the viewport's top-left to the web view's own
    /// coordinates, given the page scale (`pageZoom * magnification`).
    public static func viewPoint(css: CGPoint, scale: Double, viewHeight: Double, flipped: Bool) -> CGPoint {
        let factor = scale > 0 ? scale : 1
        let x = css.x * factor
        let y = css.y * factor
        return CGPoint(x: x, y: flipped ? y : viewHeight - y)
    }
}
