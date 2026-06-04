/// Connection-side collaborators ``MobileRecoveryCoordinator`` needs from
/// the shell facade.
///
/// The recovery coordinator owns the network-path-change + manual-Retry
/// state machine but not the connection itself: whether a recovery can be
/// attempted, whether the event stream just needs a resync, and the actual
/// reconnect all belong to ``MobileShellComposite``. This seam keeps that
/// dependency one-directional and lets tests drive the coordinator against
/// a scripted context.
@MainActor
protocol MobileConnectionRecoveryContext: AnyObject {
    /// Whether there is anything to recover: a live client or a persisted
    /// paired Mac to reconnect to.
    var canAttemptRecovery: Bool { get }

    /// Whether the shell is connected with a live RPC client, in which case
    /// recovery only resyncs the event stream instead of reconnecting.
    var hasLiveRemoteConnection: Bool { get }

    /// Whether the shell currently reports an established connection.
    var isConnected: Bool { get }

    /// Marks the Mac connection as reconnecting while the event stream is
    /// being restarted.
    func markMacConnectionReconnecting()

    /// Restarts the event stream and replays mounted surfaces.
    func resyncTerminalOutput(reason: String, restartEventStream: Bool)

    /// Reconnects to the persisted active Mac, returning whether the
    /// connection was restored.
    @discardableResult
    func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool
}
