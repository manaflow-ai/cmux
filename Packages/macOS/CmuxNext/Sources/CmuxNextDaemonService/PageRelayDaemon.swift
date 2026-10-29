public import CmuxNextDaemon

/// What a page relay needs of its daemon service: the app's main connection
/// (confirmation tokens, and the calls to a daemon without `origin-claim-v1`), its capabilities,
/// and how to open another connection to it. ``DaemonService`` in the app; a fake daemon in tests.
@MainActor
public protocol PageRelayDaemon: AnyObject {
    /// The app's main connection to the daemon; nil while not connected.
    var connection: DaemonConnection? { get }
    /// How a connection reaches the daemon; nil before the service started.
    var endpointProvider: DaemonConnection.EndpointProvider? { get }
    /// Wakes a relay connection's reconnect when the daemon may be back.
    var retryWake: RetryWake { get }
    /// Whether the connected daemon has `capability`.
    func supports(_ capability: String) -> Bool
}

extension DaemonService: PageRelayDaemon {}
