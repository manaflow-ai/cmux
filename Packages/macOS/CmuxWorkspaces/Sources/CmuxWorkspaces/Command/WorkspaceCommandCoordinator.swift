public import Foundation

/// Owns the workspace-command menu logic the app-target `cmuxApp`
/// `@CommandsBuilder` body used to compute inline: the selected-workspace index
/// math, the move-by-delta clamping, the close-other/above/below tab-list
/// slicing, and the per-item enablement that ``WorkspaceCommandMenuState``
/// carries. Lifted one-for-one from the `cmuxApp` private helpers
/// (`selectedWorkspaceIndex`, `moveSelectedWorkspace(by:)`,
/// `moveSelectedWorkspaceToTop`, `closeOtherSelectedWorkspacePeers`,
/// `closeSelectedWorkspacesBelow/Above`, `markSelectedWorkspaceRead/Unread`,
/// `workspaceCommandMenuContent`).
///
/// Reads the window's `WorkspacesModel` directly for the order/selection state
/// and forwards every irreducible app-coupled effect (pin toggle, NSAlert close
/// confirmation, cross-window move, notification mark-read/unread, palette
/// rename/edit, the legacy `TabManager` select/title mutations) through
/// ``WorkspaceCommandHosting``. The reorder moves reuse the window's existing
/// ``WorkspaceReorderCoordinator`` rather than re-implementing the order
/// surgery.
///
/// `@MainActor` because every entry point is a menu action on the main actor and
/// the model + host both live there; co-locating removes any bridging (mirrors
/// the sibling workspace coordinators' isolation ruling).
@MainActor
public final class WorkspaceCommandCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let reordering: WorkspaceReorderCoordinator<Tab>
    private weak var host: (any WorkspaceCommandHosting)?

    /// Creates the coordinator over the window's workspace model and its
    /// reorder coordinator.
    public init(
        model: WorkspacesModel<Tab>,
        reordering: WorkspaceReorderCoordinator<Tab>
    ) {
        self.model = model
        self.reordering = reordering
    }

    /// Attaches the window-side host that performs the app-coupled effects.
    public func attach(host: any WorkspaceCommandHosting) {
        self.host = host
    }

    // MARK: - Selection helpers (legacy selectedWorkspaceIndex)

    /// The selected workspace id, resolved against the window's tab order so a
    /// stale `selectedTabId` not present in `tabs` reads as no selection — exactly
    /// what the legacy `manager.selectedWorkspace` (a `tabs.first(where:)`
    /// resolution) yielded. The close flow keeps `selectedTabId` pointing at a
    /// live tab, so under that invariant this equals the raw id; resolving here
    /// preserves the legacy gating even if the invariant is ever violated.
    private var selectedWorkspaceId: UUID? {
        guard let id = model.selectedTabId,
              model.tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The index of `workspaceId` in the window's tab order, or `nil`
    /// (legacy `selectedWorkspaceIndex(in:workspaceId:)`).
    public func selectedWorkspaceIndex(workspaceId: UUID) -> Int? {
        model.tabs.firstIndex { $0.id == workspaceId }
    }

    // MARK: - Menu render state

    /// Resolves the full ``WorkspaceCommandMenuState`` the app's menu shell
    /// renders, replacing the legacy inline computation in
    /// `workspaceCommandMenuContent(manager:)`.
    public func menuState() -> WorkspaceCommandMenuState {
        guard let host else {
            return WorkspaceCommandMenuState(
                hasSelectedWorkspace: false,
                selectedWorkspaceIndex: nil,
                workspaceCount: model.tabs.count,
                selectedWorkspaceHasCustomTitle: false,
                pinToggleLabel: "",
                pinToggleEnabled: false,
                canMarkRead: false,
                canMarkUnread: false,
                windowMoveTargets: []
            )
        }
        let workspaceId = selectedWorkspaceId  // resolved against tabs (legacy manager.selectedWorkspace)
        let index = workspaceId.flatMap { selectedWorkspaceIndex(workspaceId: $0) }
        return WorkspaceCommandMenuState(
            hasSelectedWorkspace: workspaceId != nil,
            selectedWorkspaceIndex: index,
            workspaceCount: model.tabs.count,
            selectedWorkspaceHasCustomTitle: host.selectedWorkspaceHasCustomTitle,
            pinToggleLabel: host.selectedWorkspacePinToggleLabel,
            pinToggleEnabled: host.selectedWorkspaceCanTogglePin,
            canMarkRead: workspaceId.map(host.canMarkWorkspaceRead) ?? false,
            canMarkUnread: workspaceId.map(host.canMarkWorkspaceUnread) ?? false,
            windowMoveTargets: host.windowMoveTargets()
        )
    }

    // MARK: - Pin / rename / description / custom name

    /// Toggles the selected workspace's pin state (legacy
    /// `toggleSelectedWorkspacePinned`).
    public func toggleSelectedWorkspacePinned() {
        host?.toggleSelectedWorkspacePin()
    }

    /// Opens the rename-workspace palette flow (legacy menu action).
    public func renameSelectedWorkspace() {
        host?.requestRenameSelectedWorkspace()
    }

    /// Opens the edit-description palette flow (legacy menu action).
    public func editSelectedWorkspaceDescription() {
        host?.requestEditSelectedWorkspaceDescription()
    }

    /// Clears the selected workspace's custom title (legacy
    /// `clearSelectedWorkspaceCustomName`).
    public func clearSelectedWorkspaceCustomName() {
        host?.clearSelectedWorkspaceCustomName()
    }

    // MARK: - Reorder moves (reuse WorkspaceReorderCoordinator)

    /// Moves the selected workspace by `delta` in the tab order, clamped to the
    /// valid range, then re-selects it (legacy `moveSelectedWorkspace(by:)`).
    public func moveSelectedWorkspace(by delta: Int) {
        guard let workspaceId = selectedWorkspaceId,
              let currentIndex = selectedWorkspaceIndex(workspaceId: workspaceId) else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < model.tabs.count else { return }
        _ = reordering.reorderWorkspace(tabId: workspaceId, toIndex: targetIndex)
        host?.resumeWorkspaceSelectionAfterReorder(workspaceId)
    }

    /// Moves the selected workspace to the top of its tier, then re-selects it
    /// (legacy `moveSelectedWorkspaceToTop`).
    public func moveSelectedWorkspaceToTop() {
        guard let workspaceId = selectedWorkspaceId else { return }
        reordering.moveTabsToTop([workspaceId])
        host?.resumeWorkspaceSelectionAfterReorder(workspaceId)
    }

    // MARK: - Cross-window move

    /// Moves the selected workspace into the window `windowId` (legacy
    /// `moveSelectedWorkspace(toWindow:)`).
    public func moveSelectedWorkspace(toWindow windowId: UUID) {
        guard let workspaceId = selectedWorkspaceId else { return }
        host?.moveWorkspace(workspaceId, toWindow: windowId)
    }

    /// Moves the selected workspace into a new window (legacy
    /// `moveSelectedWorkspaceToNewWindow`).
    public func moveSelectedWorkspaceToNewWindow() {
        guard let workspaceId = selectedWorkspaceId else { return }
        host?.moveWorkspaceToNewWindow(workspaceId)
    }

    // MARK: - Close

    /// Closes the current workspace through the confirmation flow (legacy
    /// `manager.closeCurrentWorkspaceWithConfirmation()`).
    public func closeSelectedWorkspace() {
        host?.closeCurrentWorkspaceWithConfirmation()
    }

    /// Closes every workspace except the selected one (legacy
    /// `closeOtherSelectedWorkspacePeers`).
    public func closeOtherSelectedWorkspacePeers() {
        guard let workspaceId = selectedWorkspaceId else { return }
        let workspaceIds = model.tabs.compactMap { $0.id == workspaceId ? nil : $0.id }
        host?.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: true)
    }

    /// Closes every workspace below the selected one (legacy
    /// `closeSelectedWorkspacesBelow`).
    public func closeSelectedWorkspacesBelow() {
        guard let workspaceId = selectedWorkspaceId,
              let anchorIndex = selectedWorkspaceIndex(workspaceId: workspaceId) else { return }
        let workspaceIds = model.tabs.suffix(from: anchorIndex + 1).map(\.id)
        host?.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: true)
    }

    /// Closes every workspace above the selected one (legacy
    /// `closeSelectedWorkspacesAbove`).
    public func closeSelectedWorkspacesAbove() {
        guard let workspaceId = selectedWorkspaceId,
              let anchorIndex = selectedWorkspaceIndex(workspaceId: workspaceId) else { return }
        let workspaceIds = model.tabs.prefix(upTo: anchorIndex).map(\.id)
        host?.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: true)
    }

    // MARK: - Mark read / unread

    /// Marks the selected workspace read (legacy `markSelectedWorkspaceRead`).
    public func markSelectedWorkspaceRead() {
        guard let workspaceId = selectedWorkspaceId else { return }
        host?.markWorkspaceRead(workspaceId)
    }

    /// Marks the selected workspace unread (legacy
    /// `markSelectedWorkspaceUnread`).
    public func markSelectedWorkspaceUnread() {
        guard let workspaceId = selectedWorkspaceId else { return }
        host?.markWorkspaceUnread(workspaceId)
    }
}
