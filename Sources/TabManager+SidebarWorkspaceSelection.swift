import Foundation

/// Debounces rapid sidebar workspace-row clicks into one selection of the latest
/// target, so a click burst collapses to the last-clicked workspace.
@MainActor
final class SidebarWorkspaceSelectionCoalescer {
    private let delayNanoseconds: UInt64
    private var pendingWorkspaceId: UUID?
    private var pendingTask: Task<Void, Never>?

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func schedule(workspaceId: UUID, _ select: @escaping @MainActor (UUID) -> Void) {
        pendingWorkspaceId = workspaceId
        pendingTask?.cancel()
        let delayNanoseconds = delayNanoseconds
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  let workspaceId = self.pendingWorkspaceId
            else { return }

            self.pendingWorkspaceId = nil
            self.pendingTask = nil
            select(workspaceId)
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingWorkspaceId = nil
    }
}

extension TabManager {
    /// Debounces a normal sidebar workspace-row click. A click on the already-selected
    /// workspace instead cancels pending work and dismisses its notification directly.
    func requestSidebarWorkspaceSelection(_ workspace: Workspace) {
        if selectedTabId == workspace.id {
            cancelPendingSidebarWorkspaceSelection()
            dismissNotificationOnDirectInteraction(
                tabId: workspace.id,
                surfaceId: focusedSurfaceId(for: workspace.id)
            )
            return
        }

        sidebarWorkspaceSelectionCoalescer.schedule(workspaceId: workspace.id) { [weak self] workspaceId in
            guard let self,
                  let workspace = self.tabs.first(where: { $0.id == workspaceId })
            else { return }
            self.selectWorkspace(workspace)
        }
    }

    func cancelPendingSidebarWorkspaceSelection() {
        sidebarWorkspaceSelectionCoalescer.cancel()
    }
}
