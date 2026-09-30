import Foundation

public enum DaemonEvent: Sendable, Hashable {
    // Connection lifecycle, synthesized by `DaemonConnection`.

    /// A (re)connect finished the handshake and the subscription is live.
    /// Fetch `list-workspaces` now. `generationChanged` means every numeric
    /// handle from before is invalid and attachments must be re-created.
    case connected(DaemonIdentity, generationChanged: Bool)
    /// The socket dropped. The connection retries on its own.
    case disconnected(reason: String)

    // Tree deltas (`tree_events:"deltas"`).
    case workspaceAdded(WorkspaceDelta)
    case workspaceClosed(WorkspaceDelta)
    case workspaceRenamed(WorkspaceDelta)
    case workspaceMoved(WorkspaceDelta)
    /// Color/icon/title changed (`workspace-metadata-v1`); revisioned.
    case workspaceChanged(WorkspaceDelta)
    case screenAdded(ScreenDelta)
    case screenClosed(ScreenDelta)
    case screenRenamed(ScreenDelta)
    /// Color, icon, pin, group, or order changed (`screen-metadata-v1`); not revisioned.
    case screenChanged(ScreenDelta)
    case paneAdded(PaneDelta)
    case paneClosed(PaneDelta)
    case tabAdded(TabDelta)
    case tabClosed(TabDelta)
    case tabRenamed(TabDelta)
    /// Pin, cwd/git, or unread marker changed (`tab-metadata-v1`); not revisioned.
    case tabChanged(TabDelta)
    /// Full resync barrier: refetch `list-workspaces`. `transaction` echoes
    /// the client transaction id of the command that caused it, when any.
    case treeChanged(transaction: ClientTransactionID?)
    /// Pane geometry changed on a screen: refetch.
    case layoutChanged(screen: ScreenID, transaction: ClientTransactionID?)

    // Surface state.
    case titleChanged(surface: SurfaceID, title: String)
    case surfaceResized(surface: SurfaceID, size: CellSize)
    case surfaceExited(surface: SurfaceID)
    case scrollChanged(surface: SurfaceID, offset: UInt64, atBottom: Bool)
    case bell(surface: SurfaceID)
    case notification(DaemonNotification)
    case agentChanged(AgentStatus)

    // Registries and clients.
    case frontendProjectionChanged(ProjectionChange)
    case terminalRegistryChanged(revision: UInt64)
    /// `client-attached/changed/detached/list-invalidated`.
    case client(name: String, payload: JSONValue)
    /// The subscription ended because this client fell behind. The connection
    /// resubscribes; treat it like `treeChanged`.
    case overflow(String)
    case daemonShutdown
    case unknown(name: String, payload: JSONValue)
}
