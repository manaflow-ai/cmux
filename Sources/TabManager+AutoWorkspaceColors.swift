import CmuxSettings
import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Requests an auto workspace color reconcile on a later main-actor turn.
    ///
    /// Reconciling writes `UserDefaults`, which posts
    /// `UserDefaults.didChangeNotification` and rebuilds the sidebar settings
    /// snapshot. Doing that synchronously from a `tabs` `willSet` or from a
    /// defaults observer would re-enter the update that triggered it, so the
    /// work is always deferred and coalesced to one pass per turn.
    func scheduleAutoWorkspaceColorReconcile() {
        guard !autoWorkspaceColorReconcileScheduled else { return }
        autoWorkspaceColorReconcileScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.autoWorkspaceColorReconcileScheduled = false
            self.reconcileAutoWorkspaceColorsNow()
        }
    }

    /// Allocates colors to workspaces that need one and prunes dead entries.
    ///
    /// Existing assignments are preserved, so deleting or reordering a
    /// workspace never recolors the survivors.
    func reconcileAutoWorkspaceColorsNow(defaults: UserDefaults = .standard) {
        let keys = WorkspaceColorsCatalogSection()
        let settingsClient = UserDefaultsSettingsClient(defaults: defaults)
        guard settingsClient.value(for: keys.autoAssignColors) else {
            // Leaving stored assignments in place means turning the feature back
            // on restores the same colors instead of reshuffling them.
            return
        }

        let workspaces = tabs
        var needingAssignment: [UUID] = []
        var manualColorHexes: [String] = []
        var liveIds: Set<UUID> = []
        for workspace in workspaces {
            liveIds.insert(workspace.stableId)
            if let manual = workspace.customColor, !manual.isEmpty {
                manualColorHexes.append(manual)
            } else {
                needingAssignment.append(workspace.stableId)
            }
        }

        WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: needingAssignment,
            liveIds: liveIds,
            manualColorHexes: manualColorHexes,
            palette: WorkspaceTabColorSettings.palette(defaults: defaults),
            defaults: defaults
        )
    }

}
