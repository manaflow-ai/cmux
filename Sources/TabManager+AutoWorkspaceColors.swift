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

        let workspaces = Self.autoColorReconcileWorkspaces(fallback: self)
        // Nothing to allocate, and no point writing defaults during teardown or
        // an in-flight restore.
        guard !workspaces.isEmpty else { return }

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

    /// Workspaces from every window, because assignments are stored globally.
    ///
    /// A `TabManager` only owns one window's workspaces, so pruning against a
    /// single manager's `tabs` would delete the other windows' assignments and
    /// reshuffle their colors on the next pass.
    private static func autoColorReconcileWorkspaces(fallback: TabManager) -> [Workspace] {
        guard let app = AppDelegate.shared else { return fallback.tabs }

        var managers: [TabManager] = [fallback]
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  !managers.contains(where: { $0 === manager }) else {
                continue
            }
            managers.append(manager)
        }

        var seen: Set<UUID> = []
        var workspaces: [Workspace] = []
        for workspace in managers.flatMap(\.tabs) where seen.insert(workspace.stableId).inserted {
            workspaces.append(workspace)
        }
        return workspaces
    }
}
