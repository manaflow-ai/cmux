public import AppKit

/// A pure policy value that maps an `NSEvent.EventType` to the hit-testing and
/// drag-routing decisions the window portals share.
///
/// The window portals (browser, terminal, tab bar, drop overlays) each override
/// `hitTest(_:)` / drag routing and must decide, per incoming event, whether the
/// event should reach a particular layer. Those decisions only depend on the
/// event's coarse category (a key event never participates in pointer routing, a
/// drag event participates in pane drops, etc.), so this type folds the raw
/// `NSEvent.EventType` into an ``EventKind`` once and exposes one boolean policy
/// per routing surface. It is a value type with no AppKit view identity, so a
/// caller constructs it inline at each routing call.
public struct WindowInputRoutingContext: Equatable, Sendable {
    /// The coarse category an `NSEvent.EventType` collapses into for routing.
    ///
    /// Several distinct `NSEvent.EventType` values route identically (every
    /// mouse-down variant is ``pointerDown``, every keyboard variant is
    /// ``keyboard``), so the routing policies switch over this enum instead of
    /// the raw type. ``appKitRouting`` covers AppKit/system/application/periodic
    /// events that should pass through to AppKit's own routing.
    public enum EventKind: Equatable, Sendable {
        /// No event was supplied (a `nil` `NSEvent.EventType`).
        case noEvent
        /// A key-down, key-up, or modifier-flags-changed event.
        case keyboard
        /// A left/right/other mouse-down event.
        case pointerDown
        /// A left/right/other mouse-dragged event.
        case pointerDrag
        /// A left/right/other mouse-up event.
        case pointerUp
        /// A mouse-moved, entered, exited, or cursor-update event.
        case pointerHover
        /// A scroll-wheel event.
        case scroll
        /// An AppKit-defined, application-defined, system-defined, or periodic
        /// event that should pass through to AppKit routing.
        case appKitRouting
        /// Any event type not covered by the other cases.
        case other
    }

    /// The original `NSEvent.EventType` this context was built from, if any.
    public let eventType: NSEvent.EventType?
    /// The coarse ``EventKind`` the ``eventType`` collapses into.
    public let eventKind: EventKind

    /// Creates a routing context from an optional event.
    /// - Parameter event: The event whose type drives the routing policy, or
    ///   `nil` when no event is in flight.
    public init(event: NSEvent?) {
        self.init(eventType: event?.type)
    }

    /// Creates a routing context from an optional event type.
    /// - Parameter eventType: The event type whose category drives the routing
    ///   policy, or `nil` when no event is in flight.
    public init(eventType: NSEvent.EventType?) {
        self.eventType = eventType
        self.eventKind = Self.kind(for: eventType)
    }

    /// Whether the event should be allowed to hit-test the first-responder view.
    ///
    /// Only a pointer-down event claims first responder.
    public var allowsFirstResponderHitTesting: Bool {
        eventKind == .pointerDown
    }

    /// Whether the event should be allowed to hit-test the portal's pointer layer.
    ///
    /// Every pointer/scroll/AppKit-routed category passes through; keyboard and
    /// uncategorized events do not.
    public var allowsPortalPointerHitTesting: Bool {
        switch eventKind {
        case .noEvent,
             .pointerDown,
             .pointerDrag,
             .pointerUp,
             .pointerHover,
             .scroll,
             .appKitRouting:
            return true
        case .keyboard, .other:
            return false
        }
    }

    /// Whether the event should pass through the tab bar's hit-test.
    ///
    /// Pointer and AppKit-routed categories pass through; keyboard, scroll, and
    /// uncategorized events do not.
    public var allowsTabBarPassThroughHitTesting: Bool {
        switch eventKind {
        case .noEvent,
             .pointerDown,
             .pointerDrag,
             .pointerUp,
             .pointerHover,
             .appKitRouting:
            return true
        case .keyboard, .scroll, .other:
            return false
        }
    }

    /// Whether the event should hit-test a pane drop target.
    ///
    /// Only drag, up, hover, and AppKit-routed categories participate in pane drops.
    public var allowsPaneDropHitTesting: Bool {
        switch eventKind {
        case .pointerDrag,
             .pointerUp,
             .pointerHover,
             .appKitRouting:
            return true
        case .noEvent, .keyboard, .pointerDown, .scroll, .other:
            return false
        }
    }

    /// Whether the event should hit-test a file-drop pane target.
    ///
    /// Only drag and up events participate in file drops onto a pane.
    public var allowsFileDropPaneHitTesting: Bool {
        switch eventKind {
        case .pointerDrag, .pointerUp:
            return true
        case .noEvent, .keyboard, .pointerDown, .pointerHover, .scroll, .appKitRouting, .other:
            return false
        }
    }

    /// Whether the event should hit-test the file-drop overlay.
    ///
    /// Only a drag event keeps the overlay active.
    public var allowsFileDropOverlayHitTesting: Bool {
        eventKind == .pointerDrag
    }

    /// Whether the event should hit-test the workspace-drop overlay.
    ///
    /// A no-event, drag, cursor-update, or mouse-moved event keeps the overlay active.
    public var allowsWorkspaceDropOverlayHitTesting: Bool {
        eventKind == .noEvent
            || eventKind == .pointerDrag
            || eventType == .cursorUpdate
            || eventType == .mouseMoved
    }

    /// Whether the event should route drags to the browser portal.
    ///
    /// Only drag and hover events route to the browser portal.
    public var allowsBrowserPortalDragRouting: Bool {
        switch eventKind {
        case .pointerDrag, .pointerHover:
            return true
        case .noEvent, .keyboard, .pointerDown, .pointerUp, .scroll, .appKitRouting, .other:
            return false
        }
    }

    /// Whether the event should route drags to the terminal portal.
    ///
    /// Only a drag event routes to the terminal portal.
    public var allowsTerminalPortalDragRouting: Bool {
        eventKind == .pointerDrag
    }

    /// Convenience predicate for ``allowsTabBarPassThroughHitTesting`` from a raw
    /// event type.
    /// - Parameter eventType: The event type to evaluate.
    /// - Returns: Whether the event passes through the tab bar hit-test.
    public static func allowsTabBarPassThroughHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsTabBarPassThroughHitTesting
    }

    /// Convenience predicate for ``allowsPaneDropHitTesting`` from a raw event type.
    /// - Parameter eventType: The event type to evaluate.
    /// - Returns: Whether the event hit-tests a pane drop target.
    public static func allowsPaneDropHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsPaneDropHitTesting
    }

    /// Convenience predicate for ``allowsFileDropOverlayHitTesting`` from a raw
    /// event type.
    /// - Parameter eventType: The event type to evaluate.
    /// - Returns: Whether the event hit-tests the file-drop overlay.
    public static func allowsFileDropOverlayHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsFileDropOverlayHitTesting
    }

    /// Convenience predicate for ``allowsWorkspaceDropOverlayHitTesting`` from a
    /// raw event type.
    /// - Parameter eventType: The event type to evaluate.
    /// - Returns: Whether the event hit-tests the workspace-drop overlay.
    public static func allowsWorkspaceDropOverlayHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsWorkspaceDropOverlayHitTesting
    }

    /// Convenience predicate for ``allowsTerminalPortalDragRouting`` from a raw
    /// event type.
    /// - Parameter eventType: The event type to evaluate.
    /// - Returns: Whether the event routes drags to the terminal portal.
    public static func allowsTerminalPortalDragRouting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsTerminalPortalDragRouting
    }

    private static func kind(for eventType: NSEvent.EventType?) -> EventKind {
        guard let eventType else { return .noEvent }
        switch eventType {
        case .keyDown, .keyUp, .flagsChanged:
            return .keyboard
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .pointerDown
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .pointerDrag
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return .pointerUp
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate:
            return .pointerHover
        case .scrollWheel:
            return .scroll
        case .appKitDefined, .applicationDefined, .systemDefined, .periodic:
            return .appKitRouting
        default:
            return .other
        }
    }
}
