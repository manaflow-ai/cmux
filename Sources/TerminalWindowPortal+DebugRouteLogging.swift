import AppKit

#if DEBUG
extension WindowTerminalHostView {
    func logDragRouteDecision(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hitView: NSView?
    ) {
        let hasRelevantTypes = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes)
        guard passThrough || hasRelevantTypes else { return }

        let targetClass = hitView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let signature = [
            passThrough ? "1" : "0",
            debugEventName(eventType),
            debugPasteboardTypes(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        cmuxDebugLog(
            "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
            "event=\(debugEventName(eventType)) target=\(targetClass) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    func debugEventName(_ eventType: NSEvent.EventType?) -> String {
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
