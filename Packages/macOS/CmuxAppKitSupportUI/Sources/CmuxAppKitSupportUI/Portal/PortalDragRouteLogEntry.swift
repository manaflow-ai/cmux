#if DEBUG
public import AppKit

/// One portal drag-route decision rendered for the debug log.
///
/// Pure value type: it holds the decision inputs and derives a stable dedup
/// `signature` plus a human-readable `message`. It performs no logging, no
/// dedup bookkeeping, and no pasteboard inspection. The owning host view keeps
/// the live dedup state and decides whether to emit, then passes the resolved
/// hit-test target class string in here for formatting.
public struct PortalDragRouteLogEntry {
    public let passThrough: Bool
    public let eventType: NSEvent.EventType?
    public let pasteboardTypes: [NSPasteboard.PasteboardType]?
    public let targetClass: String

    public init(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        targetClass: String
    ) {
        self.passThrough = passThrough
        self.eventType = eventType
        self.pasteboardTypes = pasteboardTypes
        self.targetClass = targetClass
    }

    /// Stable signature used by the host view to suppress duplicate log lines.
    public var signature: String {
        [
            passThrough ? "1" : "0",
            Self.eventName(eventType),
            Self.pasteboardTypesDescription(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
    }

    /// The human-readable debug log line.
    public var message: String {
        "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
        "event=\(Self.eventName(eventType)) target=\(targetClass) " +
        "types=\(Self.pasteboardTypesDescription(pasteboardTypes))"
    }

    static func pasteboardTypesDescription(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    static func eventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDragged: return "otherMouseDragged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "other(\(eventType.rawValue))"
        }
    }
}
#endif
