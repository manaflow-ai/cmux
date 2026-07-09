public import SwiftUI
public import Foundation

/// `DropDelegate` for a sidebar workspace row that accepts a bonsplit tab-bar
/// tab dragged out of a terminal pane, moving that tab onto the hovered
/// workspace.
///
/// All app-target reads and mutations (pasteboard transfer decoding, surface
/// lookup, the bonsplit-tab move, and selection sync) route through the
/// injected ``SidebarBonsplitTabDropHosting`` seam, so the delegate never
/// imports the app-target `TabManager`/`AppDelegate`/`BonsplitTabTransferPasteboard`.
@MainActor
public struct SidebarBonsplitTabDropDelegate: DropDelegate {
    private let targetWorkspaceId: UUID
    private let host: any SidebarBonsplitTabDropHosting
    @Binding private var selectedTabIds: Set<UUID>
    @Binding private var lastSidebarSelectionIndex: Int?

    /// Creates the bonsplit-tab drop delegate.
    /// - Parameters:
    ///   - targetWorkspaceId: The hovered workspace row's id.
    ///   - host: The seam exposing bonsplit transfer/move operations and the
    ///     selection reads used to re-sync the selection anchor.
    ///   - selectedTabIds: Binding to the sidebar multi-selection.
    ///   - lastSidebarSelectionIndex: Binding to the sidebar selection anchor index.
    public init(
        targetWorkspaceId: UUID,
        host: any SidebarBonsplitTabDropHosting,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) {
        self.targetWorkspaceId = targetWorkspaceId
        self.host = host
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
    }

    public func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [host.bonsplitTabTransferTypeIdentifier]) else { return false }
        return host.currentBonsplitTransferTabId() != nil
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transferTabId = host.currentBonsplitTransferTabId() else {
            return false
        }

        if let sourceWorkspaceId = host.bonsplitSurfaceWorkspaceId(forTab: transferTabId),
           sourceWorkspaceId == targetWorkspaceId {
            syncSidebarSelection()
            return true
        }

        guard host.moveBonsplitTab(
            tabId: transferTabId,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection()
        return true
    }

    private func syncSidebarSelection() {
        if let selectedId = host.destinationSelectedTabId {
            lastSidebarSelectionIndex = host.destinationTabIds.firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}
