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

    /// Reads a workspace's stable default working directory for
    /// `workspace.get_cwd`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for fallback TabManager
    ///     resolution.
    ///   - workspaceID: The explicit workspace to read, or `nil` to read the
    ///     selected workspace in the routed TabManager.
    /// - Returns: The default-directory resolution.
    func controlGetWorkspaceDefaultDirectory(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceDefaultDirectoryResolution

    /// Sets a workspace's stable default working directory for
    /// `workspace.set_cwd`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for fallback TabManager
    ///     resolution.
    ///   - workspaceID: The explicit workspace to mutate, or `nil` to mutate
    ///     the selected workspace in the routed TabManager.
    ///   - cwd: The new default working directory.
    /// - Returns: The default-directory resolution.
    func controlSetWorkspaceDefaultDirectory(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        cwd: String
    ) -> ControlWorkspaceDefaultDirectoryResolution

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
}
