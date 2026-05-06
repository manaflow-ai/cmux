import AppKit
import Foundation

enum DragOverlayRoutingPolicy {
    static let bonsplitTabTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    static let filePreviewTransferType = NSPasteboard.PasteboardType("com.cmux.filepreview.transfer")
    static let sidebarTabReorderType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    static func hasBonsplitTabTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(bonsplitTabTransferType)
    }

    static func hasFilePreviewTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(filePreviewTransferType)
    }

    static func hasSidebarTabReorder(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(sidebarTabReorderType)
    }

    static func hasFileURL(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        PasteboardFileURLReader.hasFileURLType(pasteboardTypes ?? [])
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLocalDraggingSource: Bool
    ) -> Bool {
        // The window overlay delegates Finder/sidebar files to pane-level Bonsplit targets.
        _ = hasLocalDraggingSource
        guard hasFileURL(pasteboardTypes) else { return false }
        return true
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureFileDropDestination(
            pasteboardTypes: pasteboardTypes,
            hasLocalDraggingSource: false
        )
    }

    static func shouldCaptureFileDropOverlay(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard shouldCaptureFileDropDestination(pasteboardTypes: pasteboardTypes) else { return false }
        guard isDragMouseEvent(eventType) else { return false }
        return true
    }

    static func shouldCaptureSidebarExternalOverlay(
        hasSidebarDragState: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard hasSidebarDragState else { return false }
        return hasSidebarTabReorder(pasteboardTypes)
    }

    static func shouldCaptureSidebarExternalOverlay(
        draggedTabId: UUID?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: draggedTabId != nil,
            pasteboardTypes: pasteboardTypes
        )
    }

    static func shouldPassThroughPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return hasBonsplitTabTransfer(pasteboardTypes)
            || hasFilePreviewTransfer(pasteboardTypes)
            || hasSidebarTabReorder(pasteboardTypes)
    }

    static func shouldPassThroughTerminalPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return shouldPassThroughPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        ) || hasFileURL(pasteboardTypes)
    }

    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
    }

    private static func isPortalDragEvent(_ eventType: NSEvent.EventType?) -> Bool {
        guard let eventType else { return false }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
