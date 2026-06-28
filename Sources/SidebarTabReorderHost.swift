import CmuxSidebar
import CmuxSidebarUI
import Foundation

/// App-side adapter conforming the hovered window's `TabManager` plus the
/// `AppDelegate.shared` cross-window routing to the package
/// ``SidebarTabReorderHosting`` seam that ``SidebarTabDropDelegate`` (now in
/// `CmuxSidebarUI`) reads.
///
/// Destination reads/mutations forward to the injected `tabManager`; source and
/// window-routing operations forward to `AppDelegate.shared.tabManagerFor(tabId:)`
/// / `moveWorkspaceToWindow(...)`, matching the legacy delegate's direct
/// `AppDelegate.shared` lookups. Constructed per drop delegate at the sidebar
/// call sites, so it holds no shared state of its own.
@MainActor
final class SidebarTabReorderHost: SidebarTabReorderHosting {
    private let tabManager: TabManager
    private let tabTransferPasteboard = BonsplitTabTransferPasteboard()

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    var destinationTabIds: [UUID] { tabManager.tabs.map(\.id) }

    var destinationSelectedTabId: UUID? { tabManager.selectedTabId }

    var destinationHasWorkspaceGroups: Bool { !tabManager.workspaceGroups.isEmpty }

    func destinationGroupId(forTab tabId: UUID) -> UUID? {
        tabManager.tabs.first(where: { $0.id == tabId })?.groupId
    }

    func destinationGroupAnchor(forGroup groupId: UUID) -> UUID? {
        tabManager.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> ClosedRange<Int>? {
        tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool,
        usesTopLevelRows: Bool
    ) -> Bool {
        tabManager.reorderSidebarWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func isGroupAnchorInSourceWindow(_ draggedTabId: UUID) -> Bool {
        guard let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: draggedTabId) else {
            return false
        }
        return sourceManager.workspaceGroups.contains { $0.anchorWorkspaceId == draggedTabId }
    }

    func foreignTabIsPinned(_ id: UUID) -> Bool {
        AppDelegate.shared?
            .tabManagerFor(tabId: id)?
            .tabs.first { $0.id == id }?.isPinned ?? false
    }

    func destinationWindowId() -> UUID? {
        AppDelegate.shared?.windowId(for: tabManager)
    }

    func sourceWindowExists(forTab draggedTabId: UUID) -> Bool {
        AppDelegate.shared?.tabManagerFor(tabId: draggedTabId) != nil
    }

    func sourceSelectedWorkspaceIds(forTab draggedTabId: UUID) -> Set<UUID> {
        AppDelegate.shared?.tabManagerFor(tabId: draggedTabId)?.sidebarSelectedWorkspaceIds ?? []
    }

    func sourceWorkspaceIds(forTab draggedTabId: UUID, matching selection: Set<UUID>) -> [UUID] {
        AppDelegate.shared?
            .tabManagerFor(tabId: draggedTabId)?
            .tabs.filter { selection.contains($0.id) }.map(\.id) ?? []
    }

    func sourceGroupAnchorIds(forTab draggedTabId: UUID) -> Set<UUID> {
        Set(AppDelegate.shared?.tabManagerFor(tabId: draggedTabId)?.workspaceGroups.map(\.anchorWorkspaceId) ?? [])
    }

    func sourceTabIsPinned(forTab draggedTabId: UUID, workspaceId: UUID) -> Bool {
        AppDelegate.shared?
            .tabManagerFor(tabId: draggedTabId)?
            .tabs.first { $0.id == workspaceId }?.isPinned ?? false
    }

    @discardableResult
    func moveWorkspaceToWindow(
        workspaceId: UUID,
        windowId: UUID,
        atIndex: Int?,
        focus: Bool
    ) -> Bool {
        AppDelegate.shared?.moveWorkspaceToWindow(
            workspaceId: workspaceId,
            windowId: windowId,
            atIndex: atIndex,
            focus: focus
        ) ?? false
    }
}

/// Bonsplit-tab drop seam: forwards the package
/// ``SidebarBonsplitTabDropHosting`` reads/mutations to the bonsplit
/// tab-transfer pasteboard plus `AppDelegate.shared` surface lookup and
/// bonsplit-tab move, matching the legacy `SidebarBonsplitTabDropDelegate`'s
/// direct `AppDelegate.shared`/`BonsplitTabTransferPasteboard` use.
extension SidebarTabReorderHost: SidebarBonsplitTabDropHosting {
    var bonsplitTabTransferTypeIdentifier: String { BonsplitTabTransferPasteboard.typeIdentifier }

    func currentBonsplitTransferTabId() -> UUID? {
        tabTransferPasteboard.currentTransfer()?.tab.id
    }

    func bonsplitSurfaceWorkspaceId(forTab tabId: UUID) -> UUID? {
        AppDelegate.shared?.locateBonsplitSurface(tabId: tabId)?.workspaceId
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace workspaceId: UUID,
        focus: Bool,
        focusWindow: Bool
    ) -> Bool {
        AppDelegate.shared?.moveBonsplitTab(
            tabId: tabId,
            toWorkspace: workspaceId,
            focus: focus,
            focusWindow: focusWindow
        ) ?? false
    }
}
