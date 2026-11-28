public import AppKit

/// The AppKit event types for a driver `input.mouse` call, with the buttons
/// held across calls: a move while a button is down is a drag, as WebKit
/// expects for selections and HTML5 drag starts. The rules are Rust's
/// (cmux-browser-rules `input.rs`, ops `browser_rules_input_mouse_event` and
/// `browser_rules_input_view_point`); this keeps the held buttons between calls.
public nonisolated struct MouseEventPlan: Sendable {
    public nonisolated enum Button: String, Hashable, Sendable, Codable {
        case left, right, middle
    }

    public private(set) var held: Set<Button> = []

    public init() {}

    /// The event type for one call; `nil` for a wheel (a scroll event), an
    /// unknown type, or a library that does not answer. Updates the held buttons.
    public mutating func eventType(for type: String, button: Button) -> NSEvent.EventType? {
        let order: [Button] = [.left, .right, .middle]
        let request = MouseRequest(held: order.filter(held.contains), type: type, button: button)
        guard let reply = BrowserRulesFFI.input("mouse_event", request, as: MouseReply.self) else { return nil }
        held = Set(reply.held)
        return reply.eventType.flatMap { Self.eventTypes[$0] }
    }

    /// CSS pixels from the viewport's top-left to the web view's own
    /// coordinates, given the page scale (`pageZoom * magnification`).
    public static func viewPoint(css: CGPoint, scale: Double, viewHeight: Double, flipped: Bool) -> CGPoint {
        let request = ViewPointRequest(css: Point(x: css.x, y: css.y), scale: scale.isFinite ? scale : 0,
                                       viewHeight: viewHeight.isFinite ? viewHeight : 0, flipped: flipped)
        // The library always answers; only an app FFI pin behind the Rust lacks the op.
        guard let point = BrowserRulesFFI.input("view_point", request, as: Point.self) else { return css }
        return CGPoint(x: point.x, y: point.y)
    }

    /// `NSEvent.EventType` case names as the Rust rules write them.
    private static let eventTypes: [String: NSEvent.EventType] = [
        "mouseMoved": .mouseMoved,
        "leftMouseDragged": .leftMouseDragged, "rightMouseDragged": .rightMouseDragged,
        "otherMouseDragged": .otherMouseDragged,
        "leftMouseDown": .leftMouseDown, "rightMouseDown": .rightMouseDown, "otherMouseDown": .otherMouseDown,
        "leftMouseUp": .leftMouseUp, "rightMouseUp": .rightMouseUp, "otherMouseUp": .otherMouseUp,
    ]

    private nonisolated struct MouseRequest: Encodable {
        let held: [Button]
        let type: String
        let button: Button
    }

    private nonisolated struct MouseReply: Decodable {
        let eventType: String?
        let held: [Button]
    }

    private nonisolated struct Point: Codable {
        let x: Double
        let y: Double
    }

    private nonisolated struct ViewPointRequest: Encodable {
        let css: Point
        let scale: Double
        let viewHeight: Double
        let flipped: Bool
    }
}
