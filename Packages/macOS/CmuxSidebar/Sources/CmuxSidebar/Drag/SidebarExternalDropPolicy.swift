public import AppKit

/// Decides whether the window-level external-drop overlay should capture hit
/// testing while a sidebar workspace reorder drag is in flight.
///
/// The overlay sits over the terminal/content area and exists solely to catch a
/// sidebar reorder drag that leaves the sidebar and is released over the content
/// region, so the drag can be reset cleanly (see ``SidebarOutsideDropResetPolicy``
/// for the reset decision once the drop lands). It must only capture when both a
/// sidebar drag is active and the dragging pasteboard actually carries the
/// frozen sidebar reorder type (``SidebarTabDragPayload/typeIdentifier``);
/// otherwise it would swallow unrelated content-area interactions.
public struct SidebarExternalDropPolicy {
    /// The pasteboard type that identifies a sidebar workspace reorder drag.
    public static let sidebarTabReorderType =
        NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    public init() {}

    /// Whether the overlay should capture, given the live drag state and the
    /// current dragging-pasteboard types.
    /// - Parameters:
    ///   - hasSidebarDragState: Whether a sidebar reorder drag is in flight.
    ///   - pasteboardTypes: The types on the active drag pasteboard, or `nil`.
    /// - Returns: `true` only when a sidebar drag is active and the pasteboard
    ///   carries the sidebar reorder type.
    public func shouldCaptureSidebarExternalOverlay(
        hasSidebarDragState: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard hasSidebarDragState else { return false }
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(Self.sidebarTabReorderType)
    }

    /// Convenience overload deriving `hasSidebarDragState` from the presence of a
    /// dragged workspace id.
    /// - Parameters:
    ///   - draggedTabId: The workspace id currently being dragged, or `nil`.
    ///   - pasteboardTypes: The types on the active drag pasteboard, or `nil`.
    public func shouldCaptureSidebarExternalOverlay(
        draggedTabId: UUID?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: draggedTabId != nil,
            pasteboardTypes: pasteboardTypes
        )
    }
}
