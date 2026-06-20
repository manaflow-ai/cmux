public import Foundation

/// Per-window coordinator for the surface-metadata reads and mutations the
/// legacy `TabManager` exposed as backwards-compatibility forwarders over its
/// workspace list: the selected-workspace window title and the per-surface
/// shell-activity state.
///
/// These operate on the window's workspace ("tab") list — owned by
/// ``WorkspacesModel`` — not on any one workspace, so they live here as a
/// coordinator over the list rather than on a single ``WorkspaceTabRepresenting``.
/// The coordinator holds the model by reference (the window owns both and wires
/// them at construction) and reaches each workspace's owned title and
/// shell-activity registry through the ``WorkspaceTabRepresenting`` seam.
///
/// Directory / git-branch / PR-command-hint updates are deliberately **not**
/// here: those project onto the sidebar-git subsystem (CmuxSidebarGit), which
/// the window forwards to directly through its `SidebarGitMetadataServing` /
/// `PullRequestProbing` seams. This coordinator owns only the workspace-list
/// half of the legacy "Surface Directory Updates" section.
@MainActor
public final class SurfaceMetadataCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private weak var titleHost: (any SurfaceMetadataTitleHosting)?

    /// Identifies one pending coalesced panel-title update by its owning
    /// workspace and panel (legacy `TabManager.PanelTitleUpdateKey`).
    private struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }

    /// The trimmed titles awaiting the next coalesced flush, keyed by
    /// workspace+panel so a panel's later title supersedes its earlier one in
    /// the same burst (legacy `TabManager.pendingPanelTitleUpdates`).
    private var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]

    /// Creates the coordinator over the window's workspace-list model. The
    /// window constructs one instance and holds it; nothing re-instantiates it
    /// per call.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Injects the app-coupled title-effects seam. The window calls this at the
    /// composition point before any title update is enqueued, so the coalescer,
    /// the selected-workspace window-title refresh, and the DEBUG enqueue log
    /// reach the app target.
    public func attach(titleHost: any SurfaceMetadataTitleHosting) {
        self.titleHost = titleHost
    }

    /// Enqueues a process-reported `title` for surface `panelId` in workspace
    /// `tabId`, coalescing rapid bursts through the host's title coalescer
    /// (legacy `TabManager.enqueuePanelTitleUpdate(tabId:panelId:title:)`).
    ///
    /// An empty (whitespace-only) title is dropped. The accepted title replaces
    /// any earlier pending entry for the same panel; the host schedules the
    /// flush, which applies the whole batch on the next coalescer tick.
    public func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        titleHost?.surfaceMetadataLogPanelTitleEnqueue(
            workspaceId: tabId,
            panelId: panelId,
            title: trimmed
        )
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        titleHost?.surfaceMetadataScheduleTitleFlush { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    /// Applies every pending coalesced title update and clears the batch
    /// (legacy `TabManager.flushPendingPanelTitleUpdates()`). Called by the
    /// host's coalescer on its scheduled tick.
    public func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    /// Drops every pending coalesced title update without applying it (legacy
    /// `TabManager.pendingPanelTitleUpdates.removeAll()` during a full
    /// workspace-list reset). The window calls this from its reset path.
    public func resetPendingPanelTitleUpdates() {
        pendingPanelTitleUpdates.removeAll()
    }

    /// Commits a single flushed title onto the owning workspace and, when it is
    /// the focused panel, promotes it to the process title and (for the selected
    /// workspace) the window title (legacy
    /// `TabManager.updatePanelTitle(tabId:panelId:title:)`).
    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return }
        _ = tab.updatePanelTitle(panelId: panelId, title: title)

        if tab.focusedPanelId == panelId {
            tab.applyProcessTitle(title)
            titleHost?.surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: tabId)
        }
    }

    /// Re-applies the focused panel's current title to the process/window title
    /// after a focus change within a workspace (legacy
    /// `TabManager.focusedSurfaceTitleDidChange(tabId:)`).
    public func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        titleHost?.surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: tabId)
    }

    /// The title of the workspace with `tabId`, or `nil` when no workspace in
    /// the list has that id (legacy `TabManager.titleForTab(_:)`).
    public func titleForTab(_ tabId: UUID) -> String? {
        model.tabs.first(where: { $0.id == tabId })?.title
    }

    /// Records `state` as the shell-activity state for surface `surfaceId` in
    /// workspace `tabId`, mutating the owning workspace's registry through the
    /// ``WorkspaceTabRepresenting`` seam (legacy
    /// `TabManager.updateSurfaceShellActivity(tabId:surfaceId:state:)`, minus
    /// the pull-request refresh).
    ///
    /// Returns `true` exactly when the legacy method would schedule a
    /// pull-request refresh: the workspace exists **and** `state` is
    /// `.promptIdle`. The window performs that refresh through its
    /// `PullRequestProbing` seam, which this package does not import; the
    /// decision is surfaced here so the window-side seam call stays a thin
    /// conditional forward with no logic of its own.
    @discardableResult
    public func applySurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: PanelShellActivityState
    ) -> Bool {
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return false }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        return state == .promptIdle
    }
}
