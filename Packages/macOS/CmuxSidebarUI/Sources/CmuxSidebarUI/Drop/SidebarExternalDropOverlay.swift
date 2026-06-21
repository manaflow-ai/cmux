public import SwiftUI
internal import AppKit
internal import CmuxSidebar

/// Transparent window-level overlay that captures a sidebar workspace reorder
/// drag released outside the sidebar (over the terminal/content region).
///
/// The overlay is always present over the content area but only enables hit
/// testing while a sidebar drag is in flight and the dragging pasteboard carries
/// the sidebar reorder type (``SidebarExternalDropPolicy``). When it captures, a
/// drop routes to ``SidebarExternalDropDelegate`` which requests the drag state
/// be cleared; otherwise it is fully transparent to interaction.
@MainActor
public struct SidebarExternalDropOverlay: View {
    private let draggedTabId: UUID?

    /// Creates the external-drop overlay.
    /// - Parameter draggedTabId: The workspace id currently being dragged, or
    ///   `nil` when no sidebar drag is active.
    public init(draggedTabId: UUID?) {
        self.draggedTabId = draggedTabId
    }

    public var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = SidebarExternalDropPolicy().shouldCaptureSidebarExternalOverlay(
            draggedTabId: draggedTabId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarTabDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(draggedTabId: draggedTabId)
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}
