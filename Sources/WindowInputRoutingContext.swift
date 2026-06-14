import AppKit

struct WindowInputRoutingContext: Equatable {
    enum EventKind: Equatable {
        case noEvent
        case keyboard
        case pointerDown
        case pointerDrag
        case pointerUp
        case pointerHover
        case scroll
        case appKitRouting
        case other
    }

    let eventType: NSEvent.EventType?
    let eventKind: EventKind

    init(event: NSEvent?) {
        self.init(eventType: event?.type)
    }

    init(eventType: NSEvent.EventType?) {
        self.eventType = eventType
        self.eventKind = Self.kind(for: eventType)
    }

    var allowsFirstResponderHitTesting: Bool {
        eventKind == .pointerDown
    }

    var allowsPortalPointerHitTesting: Bool {
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

    var allowsTabBarPassThroughHitTesting: Bool {
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

    var allowsPaneDropHitTesting: Bool {
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

    var allowsFileDropPaneHitTesting: Bool {
        switch eventKind {
        case .pointerDrag, .pointerUp:
            return true
        case .noEvent, .keyboard, .pointerDown, .pointerHover, .scroll, .appKitRouting, .other:
            return false
        }
    }

    var allowsFileDropOverlayHitTesting: Bool {
        eventKind == .pointerDrag
    }

    var allowsWorkspaceDropOverlayHitTesting: Bool {
        eventKind == .noEvent
            || eventKind == .pointerDrag
            || eventType == .cursorUpdate
            || eventType == .mouseMoved
    }

    var allowsBrowserPortalDragRouting: Bool {
        switch eventKind {
        case .pointerDrag, .pointerHover:
            return true
        case .noEvent, .keyboard, .pointerDown, .pointerUp, .scroll, .appKitRouting, .other:
            return false
        }
    }

    var allowsTerminalPortalDragRouting: Bool {
        eventKind == .pointerDrag
    }

    static func allowsTabBarPassThroughHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsTabBarPassThroughHitTesting
    }

    static func allowsPaneDropHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsPaneDropHitTesting
    }

    static func allowsFileDropOverlayHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsFileDropOverlayHitTesting
    }

    static func allowsWorkspaceDropOverlayHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsWorkspaceDropOverlayHitTesting
    }

    static func allowsTerminalPortalDragRouting(eventType: NSEvent.EventType?) -> Bool {
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
