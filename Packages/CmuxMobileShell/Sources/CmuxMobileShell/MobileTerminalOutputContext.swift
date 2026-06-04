internal import CmuxMobileRPC
internal import CmuxMobileShellModel

/// Connection-side collaborators ``MobileTerminalOutputService`` needs from
/// the shell facade.
///
/// The output service owns the terminal output pipeline (event listener,
/// liveness watchdog, sequence tracking, replay) but does not own the
/// connection: the active RPC client, the connected/disconnected state, the
/// workspace list used to resolve a surface's workspace, and the
/// connection-health status surface all live in ``MobileShellComposite``.
/// This seam keeps that dependency one-directional and lets tests drive the
/// service against a scripted context.
@MainActor
protocol MobileTerminalOutputContext: AnyObject {
    /// The currently connected RPC client, or `nil` when disconnected.
    ///
    /// The service compares this by identity (`===`) against the client a
    /// task captured at start, so a response that races a reconnect can never
    /// mutate state owned by the newer connection.
    var remoteClient: MobileCoreRPCClient? { get }

    /// Whether the shell currently reports an established connection.
    var isTerminalOutputConnected: Bool { get }

    /// Resolves the workspace that owns a terminal surface, or `nil` when the
    /// surface is not in the current workspace list.
    func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID?

    /// Marks the Mac connection healthy after a successful subscribe or a
    /// received event.
    func markMacConnectionHealthy()

    /// Marks the Mac connection as reconnecting while the event stream is
    /// being restarted.
    func markMacConnectionReconnecting()

    /// Marks the Mac connection unavailable after a failed subscribe.
    func markMacConnectionUnavailable()

    /// Tears down the connection when `error` is a definitive authorization
    /// failure and returns `true`; returns `false` for non-auth errors.
    @discardableResult
    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool

    /// Schedules a workspace-list refresh in response to a
    /// `workspace.updated` push event or an event-stream restart.
    func scheduleWorkspaceListRefreshFromEvent()
}
