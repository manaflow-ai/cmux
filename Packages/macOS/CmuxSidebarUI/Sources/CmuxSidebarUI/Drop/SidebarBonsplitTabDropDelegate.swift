public import SwiftUI
public import CmuxSidebar

/// The `DropDelegate` for dropping a *bonsplit* terminal tab onto a sidebar
/// workspace row, moving that terminal into the row's workspace.
///
/// Bonsplit tab drags arrive through the AppKit `.drag` pasteboard rather than
/// the sidebar's ``SidebarDragState``, so the drag identity and the actual move
/// route through ``WorkspaceTabRouting`` (which owns the pasteboard decode and
/// the cross-window bonsplit move app-side). This delegate carries no reference
/// to the app's `TabManager`/`AppDelegate` god objects.
@MainActor
public struct SidebarBonsplitTabDropDelegate: DropDelegate {
    public let targetWorkspaceId: UUID
    public let routing: any WorkspaceTabRouting
    @Binding public var selectedTabIds: Set<UUID>
    @Binding public var lastSidebarSelectionIndex: Int?

    /// The pasteboard UTType the bonsplit terminal-tab drag carries; matches the
    /// app's `BonsplitTabDragPayload.typeIdentifier` (the frozen
    /// `com.splittabbar.tabtransfer` exported type). Held here as a constant so
    /// the delegate's `validateDrop` content-type filter needs neither the
    /// app-side payload type nor a `UniformTypeIdentifiers` import.
    private static let bonsplitTabTransferTypeIdentifier = "com.splittabbar.tabtransfer"

    public init(
        targetWorkspaceId: UUID,
        routing: any WorkspaceTabRouting,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) {
        self.targetWorkspaceId = targetWorkspaceId
        self.routing = routing
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
    }

    public func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [Self.bonsplitTabTransferTypeIdentifier]) else { return false }
        return routing.currentBonsplitDraggedTabId() != nil
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let draggedTabId = routing.currentBonsplitDraggedTabId() else {
            return false
        }

        if routing.bonsplitSurfaceOwningWorkspaceId(forTabId: draggedTabId) == targetWorkspaceId {
            syncSidebarSelection()
            return true
        }

        guard routing.moveBonsplitTab(tabId: draggedTabId, toWorkspace: targetWorkspaceId) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection()
        return true
    }

    private func syncSidebarSelection() {
        if let selectedId = routing.selectedWorkspaceId {
            lastSidebarSelectionIndex = routing.localWorkspaceIds.firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}
