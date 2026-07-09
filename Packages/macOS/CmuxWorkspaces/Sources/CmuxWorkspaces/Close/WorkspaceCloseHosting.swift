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

    // MARK: Confirmation-decision effects (legacy TabManager close-with-confirmation paths)

    /// Whether `tab` needs a confirm-close prompt, honouring the DEBUG
    /// UI-test force flag (legacy `TabManager.workspaceNeedsConfirmClose(_:)`,
    /// `CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE` + `workspace.needsConfirmClose()`).
    func needsConfirmClose(_ tab: Tab) -> Bool

    /// Marks the window's pending close as an explicit tab/session close so the
    /// remote-tmux mirror(s) are KILLED on commit rather than detached (legacy
    /// `markRemoteTmuxKillOnWindowCloseIfNeeded`: `windowId(for:)` +
    /// `remoteTmuxController.markKillSessionsOnWindowClose(windowId:)`). The
    /// coordinator only calls this once it has confirmed the batch includes a
    /// mirror, so the witness performs the window-id lookup and mark with no
    /// further gating.
    func markRemoteTmuxKillOnWindowClose()

    /// Closes the window that contains `workspaceId` via the AppKit window-close
    /// path, returning whether a window-close was actually dispatched (legacy
    /// `window.performClose(nil)` -> `true`, else
    /// `AppDelegate.shared?.closeMainWindowContainingTabId(_:)` -> `true` when an
    /// `AppDelegate` exists, else `false`). The batch whole-window branch uses
    /// the `false` result to fall through to the per-workspace loop, matching the
    /// legacy headless / no-`AppDelegate` fallthrough.
    @discardableResult
    func closeWindow(containingWorkspaceId workspaceId: UUID) -> Bool

    // MARK: Child-exit-path effects (legacy TabManager.closePanelAfterChildExited)

    /// Whether the exited surface keeps a persistent remote workspace's panel
    /// visible instead of demoting it (legacy
    /// `Workspace.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_:)`). When
    /// true the coordinator marks the attach failed and stops, so a failed remote
    /// attach is never silently replaced by a local login shell.
    func keepsPersistentRemoteSurfaceOpenAfterChildExit(_ tab: Tab, surfaceId: UUID) -> Bool

    /// Whether the child exit should demote the workspace from remote (legacy
    /// `Workspace.shouldDemoteWorkspaceAfterChildExit(surfaceId:)`). Read for both
    /// the remote-session-ended mark guard and the route-through-`closeWorkspace`
    /// decision, preserving the legacy double evaluation and its short-circuit.
    func shouldDemoteWorkspaceAfterChildExit(_ tab: Tab, surfaceId: UUID) -> Bool

    /// The workspace's live panel count (legacy `Workspace.panels.count`). The
    /// coordinator tests it against `<= 1` to decide the last-panel collapse.
    func panelCount(_ tab: Tab) -> Int

    /// Records that the remote terminal session backing `surfaceId` ended on a
    /// demoting child exit (legacy `Workspace.markRemoteTerminalSessionEnded(...)`
    /// with the SSH `relayPort` and the `allowUntracked: !isRemoteTerminalSurface`
    /// computation). The whole relay-port / untracked derivation stays app-side so
    /// the seam carries no remote-configuration type.
    func markRemoteTerminalSessionEnded(_ tab: Tab, surfaceId: UUID)

    /// Marks the persistent remote PTY attach as failed for `surfaceId` so the
    /// error surface stays visible for retry (legacy
    /// `Workspace.markPersistentRemotePTYAttachFailed(surfaceId:)`).
    func markPersistentRemotePTYAttachFailed(_ tab: Tab, surfaceId: UUID)

    /// Closes the addressed runtime surface without confirmation (legacy
    /// `TabManager.closeRuntimeSurface(tabId:surfaceId:)`). Reused for the
    /// route-through-workspace path, the headless last-workspace fallback, and
    /// the non-last-panel default branch.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID)

    /// Closes the window for the last workspace's last child exit, clearing its
    /// notifications first, returning whether an AppDelegate window context
    /// existed (legacy: when `AppDelegate.shared` exists,
    /// `notificationStore?.clearNotifications(forTabId:)` then
    /// `closeMainWindowContainingTabId(_:recordHistory: false)` and `true`; else
    /// `false`, so the coordinator falls back to `closeRuntimeSurface` for the
    /// headless / no-`AppDelegate` case).
    @discardableResult
    func closeWindowForLastChildExit(workspaceId: UUID) -> Bool

    /// Emits the legacy `surface.close.childExited` DEBUG trace for the routing
    /// decision. The host owns the `cmuxDebugLog` sink and reads the workspace's
    /// `panels.count` / `isRemoteWorkspace` to format the line; release builds
    /// make this a no-op.
    func logChildExitCloseDecision(
        _ tab: Tab,
        surfaceId: UUID,
        workspaceCount: Int,
        handlesRemoteExitThroughWorkspace: Bool,
        keepsPersistentRemoteSurfaceOpen: Bool
    )
}
