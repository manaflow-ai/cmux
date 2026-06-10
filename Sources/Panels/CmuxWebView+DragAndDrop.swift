import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Drag-and-drop type filtering
extension CmuxWebView {
    // WKWebView inherently calls registerForDraggedTypes with public.text (and others).
    // Bonsplit tab drags use NSString (public.utf8-plain-text) which conforms to public.text,
    // so AppKit's view-hierarchy-based drag routing delivers the session to WKWebView instead
    // of SwiftUI's sibling .onDrop overlays. Rejecting in draggingEntered doesn't help because
    // AppKit only bubbles up through superviews, not siblings.
    //
    // Fix: filter out text-based types that conflict with bonsplit tab drags, but keep
    // file URL types so Finder file drops and HTML drag-and-drop work.
    private static let blockedDragTypes: Set<NSPasteboard.PasteboardType> = [
        .string, // public.utf8-plain-text — matches bonsplit's NSString tab drags
        NSPasteboard.PasteboardType("public.text"),
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("com.splittabbar.tabtransfer"),
        NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder"),
    ]

    static func shouldRejectInternalPaneDrag(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarTabReorder(pasteboardTypes)
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let filtered = newTypes.filter { !Self.blockedDragTypes.contains($0) }
        if !filtered.isEmpty {
            super.registerForDraggedTypes(filtered)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return false }
        return super.performDragOperation(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return false }
        return super.prepareForDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard !Self.shouldRejectInternalPaneDrag(sender?.draggingPasteboard.types) else { return }
        super.concludeDragOperation(sender)
    }

}
