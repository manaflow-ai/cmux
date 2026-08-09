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
    ///
    /// The coalescing state is app-wide rather than per-manager because a pass
    /// allocates against every window's workspaces. Keeping it on `TabManager`
    /// made N open windows run N identical full scans for one change. It is
    /// keyed by the store a pass will reconcile, which is one shared
    /// `UserDefaults` for every window in the app.
    func scheduleAutoWorkspaceColorReconcile() {
        let store = ObjectIdentifier(autoWorkspaceColorDefaults)
        guard !Self.autoWorkspaceColorReconcileIsScheduled(store, self) else { return }
        Self.setAutoWorkspaceColorReconcileIsScheduled(true, store, self)
        Task { @MainActor [weak self] in
            // Released only once the pass is done, so the `UserDefaults` write
            // it performs cannot schedule a second, identical pass. Deferred so
            // a deallocated manager cannot strand the app-wide entry.
            defer { TabManager.setAutoWorkspaceColorReconcileIsScheduled(false, store, self) }
            self?.reconcileAutoWorkspaceColorsNow()
        }
    }

    private static func autoWorkspaceColorReconcileIsScheduled(
        _ store: ObjectIdentifier,
        _ manager: TabManager?
    ) -> Bool {
        guard let app = AppDelegate.shared else {
            return manager?.autoWorkspaceColorReconcileScheduledFallback ?? false
        }
        return app.scheduledAutoWorkspaceColorReconciles.contains(store)
    }

    private static func setAutoWorkspaceColorReconcileIsScheduled(
        _ isScheduled: Bool,
        _ store: ObjectIdentifier,
        _ manager: TabManager?
    ) {
        guard let app = AppDelegate.shared else {
            manager?.autoWorkspaceColorReconcileScheduledFallback = isScheduled
            return
        }
        if isScheduled {
            app.scheduledAutoWorkspaceColorReconciles.insert(store)
        } else {
            app.scheduledAutoWorkspaceColorReconciles.remove(store)
        }
    }

    /// Allocates colors to workspaces that need one and prunes dead entries.
    ///
    /// Existing assignments are preserved, so deleting or reordering a
    /// workspace never recolors the survivors.
    func reconcileAutoWorkspaceColorsNow(defaults explicitDefaults: UserDefaults? = nil) {
        let defaults = explicitDefaults ?? autoWorkspaceColorDefaults
        let keys = WorkspaceColorsCatalogSection()
        let settingsClient = UserDefaultsSettingsClient(defaults: defaults)
        guard settingsClient.value(for: keys.indicatorStyle)
            .automaticallyAssignsWorkspaceColors else {
            // Leaving stored assignments in place means returning to Left Rail
            // Auto restores the same colors instead of reshuffling them.
            return
        }
        // A partially restored workspace list cannot safely allocate against
        // persisted global assignments. AppDelegate schedules one complete
        // reconcile after every window has finished restoring.
        if AppDelegate.shared?.isApplyingSessionRestore == true {
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

        WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: needingAssignment,
            liveIds: liveIds,
            manualColorHexes: manualColorHexes,
            palette: WorkspaceTabColorSettings.palette(defaults: defaults)
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
