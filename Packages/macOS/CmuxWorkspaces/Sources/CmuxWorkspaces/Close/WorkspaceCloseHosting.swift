public import Foundation

/// The window-side seam ``WorkspaceCloseCoordinator`` drives for the
/// close/detach/attach **teardown effects** it cannot own from the package:
/// every reach into the app-target `Workspace` god object, `AppDelegate`
/// (remote-tmux controller, notification store, cross-window routing), the
/// `ClosedItemHistoryStore`/`SharedLiveAgentIndex` session-snapshot capture,
/// the sidebar git/PR probe services, the browser-close tracking, and the
/// `cmux.workspace.closed` lifecycle publish. The per-window `TabManager` is
/// the single conformer.
///
/// **What stays in the coordinator vs. inverts here.** The coordinator owns the
/// orchestration that is pure over the window's ``WorkspacesModel`` — the
/// guard on remaining workspace count, the `tabs` removal/insertion, the
/// group-dissolve and group-contiguity normalization, and the
/// selection-after-close index math. Those are model mutations, so they live
/// in the package next to the model. Each concrete teardown effect (snapshot
/// capture, panel teardown, remote-connection teardown, notification clear,
/// probe clears, browser unwire, remote-tmux kill, history push, lifecycle
/// publish, the empty-window backfill) inverts through one method here. The
/// **order** in which the coordinator interleaves model mutations and these
/// effects is the observable behavior; it is lifted byte-for-byte from the
/// legacy `TabManager.closeWorkspace` / `detachWorkspace` / `attachWorkspace`
/// bodies and is machine-diffable against them.
///
/// **Why `Tab` and not bare `UUID`.** The teardown reads identity-adjacent
/// god-object state the ``WorkspaceTabRepresenting`` seam deliberately does not
/// expose (`isRemoteTmuxMirror`, `isRestorableInSessionSnapshot`, the panel
/// registry, the remote connection). Passing the live `Tab` lets the app-side
/// witness reach the owning `Workspace` it already holds, exactly as the legacy
/// in-class code did, without widening the model seam with close-only members.
///
/// **Why synchronous and `@MainActor`.** Every effect is one main-actor turn
/// driven by a close/detach/attach call; the model and host both live on the
/// main actor, so co-locating removes any bridging (mirrors the sibling
/// workspace coordinators' isolation ruling). Turning teardown async would open
/// suspension windows between the ordered effects, observably changing the
/// close sequence.
@MainActor
public protocol WorkspaceCloseHosting<Tab>: AnyObject {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    // MARK: Close-path effects (legacy TabManager.closeWorkspace)

    /// Records the `workspace.close` Sentry breadcrumb with the post-close
    /// remaining-workspace count (legacy `sentryBreadcrumb("workspace.close",
    /// data: ["tabCount": tabs.count - 1])`).
    func recordWorkspaceCloseBreadcrumb(remainingTabCount: Int)

    /// Whether `tab` mirrors a remote tmux session (legacy
    /// `workspace.isRemoteTmuxMirror`).
    func isRemoteTmuxMirror(_ tab: Tab) -> Bool

    /// Kills the mirrored remote tmux session on user-initiated close (legacy
    /// `AppDelegate.shared?.remoteTmuxController.handleWorkspaceClosed(workspaceId:)`).
    func killRemoteTmuxMirror(_ tab: Tab)

    /// Whether `tab` participates in the session snapshot, gating the
    /// closed-item history push (legacy `workspace.isRestorableInSessionSnapshot`).
    func isRestorableInSessionSnapshot(_ tab: Tab) -> Bool

    /// Captures `tab`'s session snapshot and pushes the closed-workspace history
    /// entry at `index` (legacy `ClosedItemHistoryStore.shared.push(.workspace(...))`
    /// using `workspace.sessionSnapshot(...)`, the warm `SharedLiveAgentIndex`
    /// cache, and `AppDelegate.shared?.windowId(for:)`).
    func recordClosedWorkspaceHistory(_ tab: Tab, index: Int)

    /// Clears the sidebar git-metadata probes for `workspaceId` (legacy
    /// `sidebarGitMetadataService.clearWorkspaceGitProbes(workspaceId:)`).
    func clearWorkspaceGitProbes(workspaceId: UUID)

    /// Clears the pull-request probe tracking for `workspaceId` (legacy
    /// `pullRequestProbing.clearWorkspacePullRequestTracking(workspaceId:)`).
    func clearWorkspacePullRequestTracking(workspaceId: UUID)

    /// Removes `workspaceId` from the sidebar multi-selection (legacy
    /// `sidebarMultiSelection.removeFromSelection(_:)`).
    func removeFromSidebarSelection(workspaceId: UUID)

    /// Invalidates the focus-history target for `workspaceId` across all panels
    /// (legacy `invalidateFocusHistoryTarget(workspaceId:panelId: nil)`).
    func invalidateFocusHistoryTarget(workspaceId: UUID)

    /// Clears all notifications for `workspaceId` (legacy
    /// `AppDelegate.shared?.notificationStore?.clearNotifications(forTabId:)`).
    func clearNotifications(workspaceId: UUID)

    /// Tears down all of `tab`'s panels with closed-panel history suppressed
    /// (legacy `workspace.withClosedPanelHistorySuppressed { workspace.teardownAllPanels() }`).
    func teardownAllPanels(_ tab: Tab)

    /// Tears down `tab`'s remote connection (legacy
    /// `workspace.teardownRemoteConnection()`).
    func teardownRemoteConnection(_ tab: Tab)

    /// Unwires `tab`'s closed-browser tracking callback (legacy
    /// `unwireClosedBrowserTracking(for:)`, i.e. `workspace.onClosedBrowserPanel = nil`).
    func unwireClosedBrowserTracking(_ tab: Tab)

    /// Wires `tab`'s closed-browser tracking callback (legacy
    /// `wireClosedBrowserTracking(for:)`, i.e. setting `workspace.onClosedBrowserPanel`).
    func wireClosedBrowserTracking(_ tab: Tab)

    /// Removes the browser model's closed-browser panels for `workspaceId`
    /// (legacy `browserModel.removeClosedBrowserPanels(forWorkspaceId:)`).
    func removeClosedBrowserPanels(workspaceId: UUID)

    /// Clears `tab`'s back-pointer to its owning manager (legacy
    /// `workspace.owningTabManager = nil`).
    func clearOwningTabManager(_ tab: Tab)

    /// Sets `tab`'s owning manager back to this window (legacy
    /// `workspace.owningTabManager = self`).
    func setOwningTabManager(_ tab: Tab)

    /// Publishes the `cmux.workspace.closed` lifecycle event (legacy
    /// `publishCmuxWorkspaceClosed(_:)`).
    func publishWorkspaceClosed(_ tab: Tab)

    // MARK: Detach-path effects (legacy TabManager.detachWorkspace)

    /// Clears `tab`'s own group membership so the destination window does not
    /// render it as an orphaned indented row (legacy `removed.groupId = nil`).
    func clearGroupMembership(_ tab: Tab)

    /// Forgets the remembered focus for `workspaceId` (legacy
    /// `focusedSurface.forgetRememberedFocus(workspaceId:)`).
    func forgetRememberedFocus(workspaceId: UUID)

    /// Adds a fresh workspace to keep the window non-empty after the last
    /// workspace detaches (legacy `_ = addWorkspace()` in the empty branch).
    func addReplacementWorkspaceForEmptyWindow()
}
