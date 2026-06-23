public import CmuxCore
public import Foundation
public import Observation

/// The per-workspace mutable bookkeeping for the *surface* side of a remote
/// connection: which surfaces are tracked as active remote terminals, which
/// persistent PTY attaches have ended, the PTY session id assigned to each
/// surface, the relay id-alias maps, the pending TTY / port-scan-kick the next
/// tracked surface should adopt, the tmux mirror reorder/close guards, and the
/// transferred-cleanup configurations a detached terminal carries.
///
/// This was previously ~17 stored properties scattered across the `Workspace`
/// god object. It is split out here as the single owning sub-model so the
/// surface domain owns its own state instead of fusing it into the workspace.
/// `Workspace` holds a ``RemoteSurfaceCoordinator`` (which holds this state) and
/// forwards each former stored property to the matching member here, exactly
/// like its other extracted sub-models (`surfaceRegistry`, `splitLayout`).
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every mutation of these
/// properties happened inside a plain method on the `@MainActor` `Workspace`
/// class, so every read and write already ran on the main actor. There is no
/// off-main writer, so no lock and no actor are required. `@Observable` mirrors
/// the workspace's own observation surface; none of these properties had a
/// Combine `$` subscriber, so the move carries no observer-parity bridge (the
/// one published projection, the active-terminal session *count*, stays on
/// `Workspace` because it has a `CurrentValueSubject` mirror).
@MainActor
@Observable
public final class RemoteSurfaceTrackingState {
    /// Surface ids whose remote port scan reported listening ports. Tracks the
    /// keys whose `surfaceListeningPorts` entries the next snapshot must prune.
    public var remoteDetectedSurfaceIds: Set<UUID> = []

    /// Surface ids currently tracked as active remote terminals.
    public var activeRemoteTerminalSurfaceIds: Set<UUID> = []

    /// Surface ids whose persistent remote PTY attach ended but whose surface is
    /// kept open (preserve-after-exit).
    public var endedPersistentRemotePTYAttachSurfaceIds: Set<UUID> = []

    /// The remote PTY session id assigned to each surface (persistent transports).
    public var remotePTYSessionIDsByPanelId: [UUID: String] = [:]

    /// Workspace id aliases that map a snapshot/source workspace id to this
    /// workspace's id for relay command-line rewriting.
    public var remoteRelayWorkspaceIDAliases: [UUID: UUID] = [:]

    /// Surface id aliases that map a snapshot/source surface id to a restored
    /// surface id for relay command-line rewriting.
    public var remoteRelaySurfaceIDAliases: [UUID: UUID] = [:]

    /// Surface ids whose child exit is pending a workspace-demotion decision.
    public var pendingRemoteTerminalChildExitSurfaceIds: Set<UUID> = []

    /// The TTY name the next tracked remote surface should adopt, captured before
    /// the surface that owns it is tracked.
    public var pendingRemoteSurfaceTTYName: String?

    /// The surface the pending TTY was requested for, or `nil` for any surface.
    public var pendingRemoteSurfaceTTYSurfaceId: UUID?

    /// The port-scan kick reason the next tracked remote surface should adopt.
    public var pendingRemoteSurfacePortKickReason: PortScanKickReason?

    /// The surface the pending port-scan kick was requested for, or `nil`.
    public var pendingRemoteSurfacePortKickSurfaceId: UUID?

    /// tmux pane ids whose non-interactive close confirmation is in flight, the
    /// re-entrancy guard for ``requestRemoteTmuxPaneClose``.
    public var pendingRemoteTmuxPaneCloseIds: Set<Int> = []

    /// True while a reactive tmux mirror-tab reorder is rearranging tabs, so the
    /// per-move selection/focus churn is suppressed.
    public var isApplyingRemoteTmuxTabReorder = false

    /// The remote cleanup configuration a detached terminal carries so the
    /// source workspace can reclaim the SSH control master after the move.
    public var transferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] = [:]

    /// True when the last live remote terminal was detached out, so the source
    /// workspace's teardown must not shut down the SSH control master still
    /// serving the moved terminal.
    public var skipControlMasterCleanupAfterDetachedRemoteTransfer = false

    /// True while session-restore scaffolding is rebuilding the layout, so the
    /// remote terminal startup is suppressed for the transient scaffold panels.
    public var suppressRemoteTerminalStartupForSessionRestoreScaffold = false

    /// Creates an empty tracking state. The coordinator owns one per workspace.
    public init() {}
}
