public import Foundation

/// The sidebar-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella): live app reach for the v1 sidebar
/// metadata commands (`set_status` … `sidebar_state`), the v1 bonsplit pane
/// commands (`list_panes` … `new_pane`), and the v1 misc surface ops
/// (`reload_config` / `refresh_surfaces` / `surface_health` / `close_surface`
/// / `new_surface`).
///
/// `@MainActor` because its conformer lives on the main actor and the
/// coordinator runs there too (the v1 dispatcher's `v2MainSync` hops were
/// no-ops once moved). The `Schedule*` methods preserve the legacy deferred
/// mutation-bus semantics: they enqueue and return immediately, exactly as
/// the original bodies did.
@MainActor
public protocol ControlSidebarContext: AnyObject {
    // MARK: Availability

    /// Whether the active `TabManager` is wired (the legacy
    /// `guard let tabManager` head of several v1 bodies).
    func controlSidebarTabManagerAvailable() -> Bool

    // MARK: Scheduled sidebar mutations (status / agent / blocks)

    /// Enqueues the `set_status`/`report_meta` upsert mutation.
    func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?
    )

    /// Enqueues the `clear_status`/`clear_meta` removal mutation.
    func controlSidebarScheduleStatusClear(target: ControlSidebarTabTarget, key: String)

    /// Enqueues the `set_agent_pid` record mutation.
    func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?
    )

    /// Parses an agent lifecycle CLI token, returning the canonical raw value
    /// (the app owns the `AgentHibernationLifecycleState` token table).
    func controlSidebarParseAgentLifecycle(_ raw: String) -> String?

    /// Whether a lifecycle key is allowed (built-in status keys or a
    /// registered vault agent id for the target tab).
    func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool

    /// Enqueues the `set_agent_lifecycle` mutation.
    func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?
    )

    /// Workspace-scoped manual loading toggle for `workspace_loading`. `on`
    /// marks the manual loader `key` running on the workspace; `off` clears it
    /// from every panel so it turns off regardless of which surface invoked it.
    /// Returns this manual loader key's state before and after the change, or
    /// `nil` if the workspace was not found. Other active agent lifecycles may
    /// still keep the aggregate sidebar spinner visible.
    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState?

    /// Applies the `agent_hibernation` global toggle.
    func controlSidebarSetAgentHibernation(enabled: Bool)

    /// Enqueues the `clear_agent_pid` mutation.
    func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool
    )

    /// Enqueues the `report_meta_block` upsert mutation.
    func controlSidebarScheduleMetadataBlockUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        markdown: String,
        priority: Int
    )

    // MARK: Synchronous metadata reads / writes

    /// Status entries in display order, or `nil` when the tab can't resolve.
    func controlSidebarStatusEntries(tabArg: String?) -> [ControlSidebarStatusEntrySnapshot]?

    /// Metadata blocks in display order, or `nil` when the tab can't resolve.
    func controlSidebarMetadataBlocks(tabArg: String?) -> [ControlSidebarMetadataBlockSnapshot]?

    /// Removes one metadata block (`clear_meta_block`).
    func controlSidebarClearMetadataBlock(tabArg: String?, key: String) -> ControlSidebarClearMetaBlockResolution

    /// Whether a raw log level token is valid (`SidebarLogLevel` raw values).
    func controlSidebarIsValidLogLevel(_ raw: String) -> Bool

    /// Appends a log entry (`log`); `false` when the tab can't resolve.
    func controlSidebarAppendLog(
        tabArg: String?,
        message: String,
        levelRawValue: String,
        source: String?
    ) -> Bool

    /// Clears the log (`clear_log`); `false` when the tab can't resolve.
    func controlSidebarClearLog(tabArg: String?) -> Bool

    /// All log entries in order, or `nil` when the tab can't resolve.
    func controlSidebarLogEntries(tabArg: String?) -> [ControlSidebarLogEntrySnapshot]?

    /// Sets progress (`set_progress`); `false` when the tab can't resolve.
    func controlSidebarSetProgress(tabArg: String?, value: Double, label: String?) -> Bool

    /// Clears progress (`clear_progress`); `false` when the tab can't resolve.
    func controlSidebarClearProgress(tabArg: String?) -> Bool

    // MARK: Git branch

    /// Enqueues the explicit-scope `report_git_branch` update (off-main
    /// telemetry path).
    func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    )

    /// Applies the fallback `report_git_branch` update; `false` when the tab
    /// can't resolve.
    func controlSidebarUpdateGitBranch(tabArg: String?, branch: String, isDirty: Bool?) -> Bool

    /// Enqueues the explicit-scope `clear_git_branch` update.
    func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope)

    /// Applies the fallback `clear_git_branch`; `false` when the tab can't
    /// resolve.
    func controlSidebarClearGitBranch(tabArg: String?) -> Bool

    // MARK: Pull requests (panel metadata mutations)

    /// Whether a raw PR state token is valid (`SidebarPullRequestStatus` raw
    /// values).
    func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool

    /// Enqueues the `report_pr` panel pull-request update.
    func controlSidebarSchedulePanelPullRequestUpdate(
        target: ControlSidebarPanelMutationTarget,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    )

    /// Enqueues the `clear_pr` panel pull-request clear.
    func controlSidebarSchedulePanelPullRequestClear(target: ControlSidebarPanelMutationTarget)

    /// Enqueues the `report_pr_action` command hint.
    func controlSidebarSchedulePanelPullRequestAction(
        target: ControlSidebarPanelMutationTarget,
        action: String,
        actionTarget: String?
    )

    // MARK: Ports / pwd / shell state / tty / kick

    /// Applies the `report_ports` write (`panelArg` is the raw
    /// `--panel`/`--surface` option; `nil` = focused surface). Tab resolution
    /// and pruning run before the panel checks, preserving legacy ordering.
    func controlSidebarSetPorts(tabArg: String?, panelArg: String?, ports: [Int]) -> ControlSidebarPanelWriteResolution

    /// Applies the `clear_ports` write (`nil` panel argument = clear all).
    func controlSidebarClearPorts(tabArg: String?, panelArg: String?) -> ControlSidebarPanelWriteResolution

    /// Enqueues the explicit-scope `report_pwd` directory update.
    /// `displayLabel` carries the optional human-friendly sidebar label
    /// reported alongside the real filesystem path (`--path=`).
    func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String, displayLabel: String?)

    /// Applies the fallback `report_pwd` directory update.
    func controlSidebarUpdateDirectory(tabArg: String?, panelArg: String?, directory: String, displayLabel: String?) -> ControlSidebarPanelWriteResolution

    /// Runs the explicit-scope `report_shell_state` fast path (dedupe gate +
    /// enqueue).
    func controlSidebarScheduleScopedShellState(scope: ControlSidebarPanelScope, stateRawValue: String)

    /// Applies the fallback `report_shell_state` update.
    func controlSidebarUpdateShellState(tabArg: String?, panelArg: String?, stateRawValue: String) -> ControlSidebarPanelWriteResolution

    /// Enqueues the explicit-scope `report_tty` registration.
    func controlSidebarScheduleScopedTTY(scope: ControlSidebarPanelScope, ttyName: String)

    /// Applies the fallback `report_tty` registration.
    func controlSidebarReportTTY(tabArg: String?, panelArg: String?, ttyName: String) -> ControlSidebarPanelWriteResolution

    /// Enqueues the explicit-scope `ports_kick`.
    func controlSidebarScheduleScopedPortsKick(scope: ControlSidebarPanelScope, reasonRawValue: String)

    /// Applies the fallback `ports_kick`.
    func controlSidebarPortsKick(tabArg: String?, panelArg: String?, reasonRawValue: String) -> ControlSidebarPanelWriteResolution

    // MARK: State / reset / right sidebar

    /// Snapshots the full sidebar context (`sidebar_state`), or `nil` when the
    /// tab can't resolve.
    func controlSidebarStateSnapshot(tabArg: String?) -> ControlSidebarStateSnapshot?

    /// Resets the sidebar context (`reset_sidebar`); `false` when the tab
    /// can't resolve.
    func controlSidebarReset(tabArg: String?) -> Bool

    /// Parses and applies a `right_sidebar` remote command from pre-tokenized
    /// args (parse + apply stay app-side; the parser is shared with the
    /// socket focus-policy path).
    func controlSidebarApplyRightSidebarRemoteCommand(tokens: [String]) -> ControlSidebarRightSidebarResolution

    // MARK: Bonsplit pane ops

    /// Snapshots the selected workspace's panes (`list_panes`), or `nil` when
    /// no workspace is selected.
    func controlSidebarPaneList() -> ControlSidebarPaneListSnapshot?

    /// Resolves and lists one pane's bonsplit tabs (`list_pane_surfaces`).
    func controlSidebarPaneSurfaces(paneArg: String?) -> ControlSidebarPaneSurfacesResolution

    /// Focuses a pane by UUID-or-index argument (`focus_pane`).
    func controlSidebarFocusPane(paneArg: String) -> Bool

    /// Focuses a surface by panel UUID (`focus_surface_by_panel`).
    func controlSidebarFocusSurfaceByPanel(panelID: UUID) -> Bool

    /// Refreshes the `kind:N` handle registry from live app state (the legacy
    /// `v2RefreshKnownRefs` pre-pass of `drag_surface_to_split`).
    func controlSidebarRefreshKnownRefs()

    /// Forwards a stable-ref `drag_surface_to_split` to the shared app-side
    /// `v2SurfaceSplitOff` body.
    func controlSidebarSplitOffSurface(surfaceID: UUID, directionRawValue: String) -> ControlSidebarSplitOffOutcome

    /// Runs the `drag_surface_to_split` fallback (selected-workspace surface
    /// argument resolution + bonsplit move).
    func controlSidebarDragSurfaceToSplit(
        surfaceArg: String,
        orientationIsHorizontal: Bool,
        insertFirst: Bool
    ) -> ControlSidebarDragToSplitResolution

    /// Creates a `new_pane` split off the focused panel (focus allowance is
    /// read app-side from the active socket-command policy, as the original
    /// did). Terminal splits on a remote tmux mirror workspace are routed to
    /// the remote instead of created locally — the resolution distinguishes
    /// that from failure.
    func controlSidebarCreatePaneSplit(
        isBrowser: Bool,
        orientationIsHorizontal: Bool,
        insertFirst: Bool,
        url: URL?
    ) -> ControlSidebarPaneSplitResolution

    /// Creates a `new_surface` in a pane (UUID-or-index argument, focused
    /// pane otherwise).
    func controlSidebarNewSurface(isBrowser: Bool, paneArg: String?, url: URL?) -> ControlSidebarNewSurfaceResolution

    /// Closes a surface (`close_surface`; empty argument = focused surface).
    func controlSidebarCloseSurface(surfaceArg: String?) -> ControlSidebarCloseSurfaceResolution

    // MARK: Misc ops

    /// Reloads the Ghostty configuration (`reload_config`).
    func controlSidebarReloadConfig()

    /// Force-refreshes the selected workspace's terminal panels
    /// (`refresh_surfaces`); returns the refreshed count.
    func controlSidebarRefreshSurfaces() -> Int

    /// Snapshots panel health rows (`surface_health`), or `nil` when the tab
    /// can't resolve.
    func controlSidebarSurfaceHealth(tabArg: String) -> [ControlSidebarSurfaceHealthRow]?
}
