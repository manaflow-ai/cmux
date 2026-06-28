public import Foundation

/// The workspace-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella), covering the non-group `workspace.*`
/// methods.
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by resolving a `TabManager`/`Workspace` from the routing selectors
/// (the legacy `v2ResolveTabManager` precedence, or the workspace-owner-first
/// resolutions some bodies used) and reading/mutating live state. Every method
/// is `@MainActor` because its conformer and the coordinator both live on the
/// main actor, so these are plain in-isolation calls — the per-read `v2MainSync`
/// hops the legacy bodies used disappear once the domain moves onto the
/// coordinator.
///
/// No app types (`TabManager` / `Workspace` / `AppDelegate`) cross the seam:
/// each method takes pre-parsed selectors/ids/inputs and returns Sendable
/// snapshots, resolution enums, Bools, or optionals. App-typed payloads (the
/// `remoteStatusPayload()` object) cross as bridged ``JSONValue``s. Localized
/// error messages are supplied through ``ControlWorkspaceStrings`` so they
/// resolve against the app bundle.
@MainActor
public protocol ControlWorkspaceContext: AnyObject {
    /// The localized workspace error messages, resolved against the app bundle.
    func controlWorkspaceStrings() -> ControlWorkspaceStrings

    /// Whether the routing selectors resolve a TabManager, used to reproduce the
    /// legacy `unavailable`-first ordering for `workspace.reorder` /
    /// `workspace.next` / `previous` / `last` before their param/state work.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: Whether a TabManager resolves.
    func controlWorkspaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool

    /// Snapshots every workspace for `workspace.list`.
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The list resolution.
    func controlWorkspaceList(routing: ControlRoutingSelectors) -> ControlWorkspaceListResolution

    /// Snapshots the selected workspace for `workspace.current`.
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The current resolution.
    func controlWorkspaceCurrent(routing: ControlRoutingSelectors) -> ControlWorkspaceCurrentResolution

    /// Creates a workspace for `workspace.create`, forwarding to the shared
    /// `v2WorkspaceCreate` body (also driven by the mobile data-plane create
    /// path) and bridging its Foundation payload — a single source of truth.
    ///
    /// - Parameter params: The raw command params; the body parses them and mints
    ///   refs itself.
    /// - Returns: The bridged call result.
    func controlWorkspaceCreate(params: [String: JSONValue]) -> ControlCallResult

    /// Selects a workspace for `workspace.select` (focuses its window when it
    /// belongs to another window).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The workspace to select.
    /// - Returns: The routed resolution.
    func controlSelectWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceRoutedResolution

    /// Closes a workspace for `workspace.close`, honoring the pinned-protection
    /// guard.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The workspace to close.
    /// - Returns: The close resolution.
    func controlCloseWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceCloseResolution

    /// Moves a workspace to another window for `workspace.move_to_window`.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to move.
    ///   - windowID: The destination window.
    ///   - focus: Whether to focus the destination (already through the app's
    ///     focus-allowance gate app-side).
    /// - Returns: The move resolution.
    func controlMoveWorkspaceToWindow(
        workspaceID: UUID,
        windowID: UUID,
        focusRequested: Bool
    ) -> ControlWorkspaceMoveToWindowResolution

    /// Reorders a single workspace for `workspace.reorder`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The workspace to move.
    ///   - toIndex: The absolute target index, if provided.
    ///   - beforeWorkspaceID: The peer to move before, if provided.
    ///   - afterWorkspaceID: The peer to move after, if provided.
    ///   - dryRun: Whether to only plan (no mutation).
    /// - Returns: The reorder resolution.
    func controlReorderWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        toIndex: Int?,
        beforeWorkspaceID: UUID?,
        afterWorkspaceID: UUID?,
        dryRun: Bool
    ) -> ControlWorkspaceReorderResolution

    /// Reorders many workspaces for `workspace.reorder_many`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for the special TabManager
    ///     resolution (explicit `window_id` wins, else the first owning
    ///     workspace, else the routing fallback).
    ///   - workspaceIDs: The desired order, already resolved from refs.
    ///   - dryRun: Whether to only plan (no mutation).
    /// - Returns: The reorder-many resolution.
    func controlReorderWorkspacesMany(
        routing: ControlRoutingSelectors,
        workspaceIDs: [UUID],
        dryRun: Bool
    ) -> ControlWorkspaceReorderManyResolution

    /// Submits a prompt for `workspace.prompt_submit`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for the fallback TabManager.
    ///   - workspaceID: The workspace to submit into (resolved owner-first).
    ///   - message: The selected message text, if any.
    /// - Returns: The prompt-submit resolution.
    func controlSubmitWorkspacePrompt(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        message: String?
    ) -> ControlWorkspacePromptSubmitResolution

    /// Renames a workspace for `workspace.rename`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The workspace to rename.
    ///   - title: The new (trimmed, non-empty) title.
    /// - Returns: The routed resolution.
    func controlRenameWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        title: String
    ) -> ControlWorkspaceRoutedResolution

    /// Selects the next workspace for `workspace.next`.
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The navigation resolution.
    func controlSelectNextWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution

    /// Selects the previous workspace for `workspace.previous`.
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The navigation resolution.
    func controlSelectPreviousWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution

    /// Navigates to the last-visited workspace for `workspace.last`.
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The navigation resolution.
    func controlSelectLastWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution

    /// Equalizes splits for `workspace.equalize_splits`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager + workspace
    ///     resolution.
    ///   - orientationFilter: The optional `orientation` filter, trimmed
    ///     non-empty or `nil`.
    /// - Returns: The equalize resolution.
    func controlEqualizeWorkspaceSplits(
        routing: ControlRoutingSelectors,
        orientationFilter: String?
    ) -> ControlWorkspaceEqualizeResolution

    /// Runs `workspace.remote.configure`. The body is app-typed end to end (it
    /// validates ~40 params against `WorkspaceRemote*` app types and mutates the
    /// workspace), so the coordinator passes the raw params and the resolved
    /// workspace id through, and the app returns the fully shaped result.
    ///
    /// - Parameters:
    ///   - params: The raw command params.
    ///   - workspaceID: The resolved workspace id (explicit-or-selected
    ///     fallback already applied by the coordinator).
    /// - Returns: The fully shaped call result.
    func controlConfigureWorkspaceRemote(
        params: [String: JSONValue],
        workspaceID: UUID
    ) -> ControlCallResult

    /// Disconnects a remote workspace for `workspace.remote.disconnect`.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - clearConfiguration: Whether to clear the stored configuration.
    /// - Returns: The remote resolution.
    func controlDisconnectWorkspaceRemote(
        workspaceID: UUID,
        clearConfiguration: Bool
    ) -> ControlWorkspaceRemoteResolution

    /// Reconnects a remote workspace for `workspace.remote.reconnect`.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - surfaceID: The optional reconnecting placeholder surface id.
    /// - Returns: The remote resolution (may signal `notConfigured`).
    func controlReconnectWorkspaceRemote(
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlWorkspaceRemoteResolution

    /// Notifies foreground-auth readiness for
    /// `workspace.remote.foreground_auth_ready`.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - foregroundAuthToken: The trimmed token, if any.
    /// - Returns: The remote resolution.
    func controlWorkspaceRemoteForegroundAuthReady(
        workspaceID: UUID,
        foregroundAuthToken: String?
    ) -> ControlWorkspaceRemoteResolution

    /// Reads remote status for `workspace.remote.status`.
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    /// - Returns: The remote resolution.
    func controlWorkspaceRemoteStatus(workspaceID: UUID) -> ControlWorkspaceRemoteResolution

    /// Resolves the workspace id for the remote methods that fall back to the
    /// routed selected workspace when no explicit `workspace_id` was given,
    /// mirroring `requestedWorkspaceId ?? fallbackTabManager?.selectedTabId`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for the fallback TabManager.
    ///   - requestedWorkspaceID: The explicit workspace id, if any.
    /// - Returns: The resolved workspace id, or `nil` (legacy "Missing
    ///   workspace_id").
    func controlResolveRemoteWorkspaceID(
        routing: ControlRoutingSelectors,
        requestedWorkspaceID: UUID?
    ) -> UUID?

    /// Records a remote PTY attach-end for `workspace.remote.pty_attach_end`.
    ///
    /// - Parameters:
    ///   - workspaceID: The requested workspace id.
    ///   - surfaceID: The surface id.
    ///   - sessionID: The (non-empty) session id.
    /// - Returns: The attach-end resolution.
    func controlWorkspaceRemotePTYAttachEnd(
        workspaceID: UUID,
        surfaceID: UUID,
        sessionID: String
    ) -> ControlWorkspaceRemotePTYAttachEndResolution

    /// Records a remote terminal session-end for
    /// `workspace.remote.terminal_session_end`.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace id.
    ///   - surfaceID: The surface id.
    ///   - relayPort: The validated relay port.
    /// - Returns: The session-end resolution.
    func controlWorkspaceRemoteTerminalSessionEnd(
        workspaceID: UUID,
        surfaceID: UUID,
        relayPort: Int
    ) -> ControlWorkspaceRemoteTerminalSessionEndResolution

    // MARK: - Set auto title

    /// Whether workspace auto-naming is enabled in Settings, for the
    /// `workspace.set_auto_title` non-probe gate (the legacy `disabled` error
    /// reads this first).
    ///
    /// - Returns: The auto-naming enabled flag.
    func controlWorkspaceAutoNamingEnabled() -> Bool

    /// Builds the `workspace.set_auto_title` probe snapshot: the enabled flag,
    /// the summarizer agent slug to report, and (only when `hasWorkspaceID` and a
    /// TabManager resolves) whether the user owns the workspace's title.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - hasWorkspaceID: Whether the request carried a `workspace_id` param
    ///     (a valid one, already parsed by the coordinator).
    ///   - workspaceID: The parsed `workspace_id`, if present.
    /// - Returns: The probe snapshot.
    func controlWorkspaceAutoTitleProbe(
        routing: ControlRoutingSelectors,
        hasWorkspaceID: Bool,
        workspaceID: UUID?
    ) -> ControlWorkspaceAutoTitleProbe

    /// Records an auto-naming failure on the Settings status line for the
    /// `workspace.set_auto_title` `failure` branch (it never reaches a workspace
    /// or tab title).
    ///
    /// - Parameters:
    ///   - rawCategory: The raw `failure` category string.
    ///   - agent: The reporting `agent` string (empty when absent).
    func controlRecordAutoNamingFailure(rawCategory: String, agent: String)

    /// Applies an auto-generated title for `workspace.set_auto_title`: resolves
    /// the workspace, sets its title with the `.auto` source, optionally sets a
    /// panel title, and clears any stale auto-naming failure when the workspace
    /// title applied.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The target workspace.
    ///   - title: The trimmed, non-empty title.
    ///   - panelID: The optional panel id (or surface id) to also title.
    ///   - panelOnlyIfMultiple: Whether to skip the panel title when the
    ///     workspace has fewer than two panels.
    /// - Returns: The apply resolution.
    func controlApplyWorkspaceAutoTitle(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        title: String,
        panelID: UUID?,
        panelOnlyIfMultiple: Bool
    ) -> ControlWorkspaceSetAutoTitleResolution

    // MARK: - Env

    /// Reads a workspace's user-defined environment for `workspace.env`
    /// (issue #5995). Resolves strictly for explicit targets (the coordinator
    /// already validated each explicit-target key), falling back to the selected
    /// workspace only when no explicit target was supplied.
    ///
    /// - Parameter routing: The routing selectors used for TabManager +
    ///   workspace resolution.
    /// - Returns: The env resolution.
    func controlWorkspaceEnv(routing: ControlRoutingSelectors) -> ControlWorkspaceEnvResolution

    // MARK: - v1 line-protocol witnesses

    /// The v1 `list_workspaces` body: lists the active controller's workspaces.
    ///
    /// The v1 command read the controller's own active `TabManager` directly
    /// (erroring when absent) and emitted flat `<sel> <idx>: <uuid> <title>`
    /// lines, distinct from the JSON `workspace.list`, so it carries its own
    /// witness.
    ///
    /// - Returns: The flat v1 reply line(s).
    func controlListWorkspacesV1() -> String

    /// The v1 `current_workspace` body: the active controller's selected
    /// workspace id.
    ///
    /// - Returns: The flat v1 reply line.
    func controlCurrentWorkspaceV1() -> String

    /// The v1 `new_workspace` body: creates a workspace in the active
    /// controller's `TabManager`, selecting/eager-loading per the active
    /// focus-allowance gate, and returns the flat `OK <uuid>` line.
    ///
    /// - Parameter args: The raw (trimmed-to-title) argument remainder.
    /// - Returns: The flat v1 reply line.
    func controlNewWorkspaceV1(args: String) -> String

    /// The v1 `new_split` body: parses `<direction> [panel]`, resolves the
    /// target surface (explicit panel or the focused one), rejects a left/up
    /// split in a remote tmux mirror, and creates the split.
    ///
    /// - Parameter args: The raw argument remainder.
    /// - Returns: The flat v1 reply line.
    func controlNewSplitV1(args: String) -> String

    /// The v1 `close_workspace` body: parses the workspace id, honors the
    /// pinned-protection guard, and closes the tab.
    ///
    /// - Parameter arg: The raw workspace-id argument.
    /// - Returns: The flat v1 reply line.
    func controlCloseWorkspaceV1(arg: String) -> String

    /// The v1 `select_workspace` body: selects a workspace by UUID or by index
    /// in the active controller's `TabManager`. The v1 path selects in place
    /// (no cross-window focus or `setActiveTabManager`), distinct from
    /// `workspace.select`, so it carries its own witness.
    ///
    /// - Parameter arg: The raw UUID-or-index argument.
    /// - Returns: The flat v1 reply line.
    func controlSelectWorkspaceV1(arg: String) -> String

    // MARK: - workspace.action

    /// The effective workspace tab-color palette snapshot, read for the
    /// non-blank `set_color` path of `workspace.action` so
    /// ``ControlWorkspaceActionResolution`` can match a requested color name and
    /// echo the available names on failure (the legacy
    /// `WorkspaceTabColorSettings.palette()` read).
    ///
    /// - Returns: The palette entries, in `palette()` order.
    func controlWorkspaceColorPalette() -> [ControlWorkspaceColorPaletteEntry]

    /// Resolves the `workspace.action` target: applies the routing precedence to
    /// find the TabManager, the `workspace_id ?? selectedTabId` fallback, and the
    /// owning window (`v2ResolveWindowId`). Returns `nil` when the workspace
    /// cannot be located (legacy `not_found`).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - requestedWorkspaceID: The explicit `workspace_id` param, if any.
    /// - Returns: The resolved target, or `nil`.
    func controlWorkspaceActionResolveTarget(
        routing: ControlRoutingSelectors,
        requestedWorkspaceID: UUID?
    ) -> ControlWorkspaceActionTarget?

    /// Pins or unpins the workspace (`pin` / `unpin`).
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - pinned: The new pinned state.
    func controlWorkspaceActionSetPinned(workspaceID: UUID, pinned: Bool)

    /// Sets the workspace's custom title to the trimmed value (`rename`).
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - title: The trimmed, non-empty title.
    func controlWorkspaceActionSetCustomTitle(workspaceID: UUID, title: String)

    /// Clears the workspace's custom title (`clear_name`).
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    /// - Returns: The workspace's resulting (post-clear) title, for the `title`
    ///   payload.
    func controlWorkspaceActionClearCustomTitle(workspaceID: UUID) -> String

    /// Sets the workspace's custom description to the raw value
    /// (`set_description`).
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - description: The validated description value.
    /// - Returns: The workspace's resulting (post-set) custom description, for
    ///   the `description` payload.
    func controlWorkspaceActionSetCustomDescription(workspaceID: UUID, description: String) -> String?

    /// Clears the workspace's custom description (`clear_description`).
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    func controlWorkspaceActionClearCustomDescription(workspaceID: UUID)

    /// Reorders the workspace one slot (`move_up` / `move_down`), applying the
    /// legacy index clamp and re-reading the resulting index.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - direction: The reorder direction.
    /// - Returns: The reorder outcome.
    func controlWorkspaceActionReorder(
        workspaceID: UUID,
        direction: ControlWorkspaceActionReorderDirection
    ) -> ControlWorkspaceActionReorderOutcome

    /// Moves the workspace to the top (`move_top`).
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    /// - Returns: The workspace's resulting index, or `nil` when it could not be
    ///   located after the move, for the `index` payload.
    func controlWorkspaceActionMoveTop(workspaceID: UUID) -> Int?

    /// Closes the scoped sibling workspaces (`close_others` / `close_above` /
    /// `close_below`), honoring the pinned-protection guard.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - scope: Which siblings to close.
    /// - Returns: The close outcome.
    func controlWorkspaceActionClose(
        workspaceID: UUID,
        scope: ControlWorkspaceActionCloseScope
    ) -> ControlWorkspaceActionCloseOutcome

    /// Marks the workspace read (`mark_read`).
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    func controlWorkspaceActionMarkRead(workspaceID: UUID)

    /// Marks the workspace unread (`mark_unread`).
    ///
    /// - Parameter workspaceID: The resolved workspace id.
    func controlWorkspaceActionMarkUnread(workspaceID: UUID)

    /// Sets the workspace's tab color to the resolved hex, or clears it when
    /// `nil` (`set_color` / `clear_color`).
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - hex: The resolved hex color, or `nil` to clear.
    func controlWorkspaceActionSetTabColor(workspaceID: UUID, hex: String?)
}
