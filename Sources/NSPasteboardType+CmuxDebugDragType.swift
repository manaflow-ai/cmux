#if DEBUG
import AppKit

extension NSPasteboard.PasteboardType {
    /// Maps a drag-type token (named alias or explicit UTI) to the matching
    /// pasteboard type, or `nil` for an unknown bare token. Used by the
    /// `seed_drag_pasteboard_types` debug probe; lives as a static factory on
    /// the pasteboard type it produces.
    static func cmuxDebugDragType(from token: String) -> NSPasteboard.PasteboardType? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fileurl", "file-url", "public.file-url":
            return .fileURL
        case "tabtransfer", "tab-transfer", "com.splittabbar.tabtransfer":
            return DragOverlayRoutingPolicy.bonsplitTabTransferType
        case "sidebarreorder", "sidebar-reorder", "sidebar_tab_reorder",
            "com.cmux.sidebar-tab-reorder":
            return DragOverlayRoutingPolicy.sidebarTabReorderType
        default:
            // Allow explicit UTI strings for ad-hoc debug probes.
            guard token.contains(".") else { return nil }
            return NSPasteboard.PasteboardType(token)
        }
    }
}
#endif
