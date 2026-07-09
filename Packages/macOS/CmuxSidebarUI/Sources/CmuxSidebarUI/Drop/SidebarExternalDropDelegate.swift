public import SwiftUI
internal import CmuxFoundation
internal import CmuxSidebar
#if DEBUG
internal import CMUXDebugLog
#endif

/// `DropDelegate` for the window-level overlay that sits over the content area
/// while a sidebar workspace reorder drag is in flight.
///
/// Its only job is to detect a sidebar reorder drag that is released outside the
/// sidebar (over the terminal/content region) and request that the drag state be
/// cleared, so a stray drop never leaves the sidebar stuck in a dragging state.
/// The reset decision lives in ``SidebarOutsideDropResetPolicy``; the clear is
/// broadcast through ``SidebarDragLifecycleNotification``. It reasons only over
/// the injected dragged workspace id and the drop payload, holding no store
/// reference, so it respects the sidebar snapshot boundary.
@MainActor
public struct SidebarExternalDropDelegate: DropDelegate {
    private let draggedTabId: UUID?

    /// Creates the external-drop delegate.
    /// - Parameter draggedTabId: The workspace id currently being dragged, or
    ///   `nil` when no sidebar drag is active.
    public init(draggedTabId: UUID?) {
        self.draggedTabId = draggedTabId
    }

    public func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy().shouldResetDrag(
            draggedTabId: draggedTabId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        logDebugEvent(
            "sidebar.dropOutside.validate tab=\(Self.debugShortSidebarTabId(draggedTabId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    public func dropEntered(info: DropInfo) {
#if DEBUG
        logDebugEvent("sidebar.dropOutside.entered tab=\(Self.debugShortSidebarTabId(draggedTabId))")
#endif
    }

    public func dropExited(info: DropInfo) {
#if DEBUG
        logDebugEvent("sidebar.dropOutside.exited tab=\(Self.debugShortSidebarTabId(draggedTabId))")
#endif
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        logDebugEvent("sidebar.dropOutside.updated tab=\(Self.debugShortSidebarTabId(draggedTabId)) op=move")
#endif
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        logDebugEvent("sidebar.dropOutside.perform tab=\(Self.debugShortSidebarTabId(draggedTabId))")
#endif
        SidebarDragLifecycleNotification().postClearRequest(reason: "outside_sidebar_drop")
        return true
    }

#if DEBUG
    private static func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
#endif
}
