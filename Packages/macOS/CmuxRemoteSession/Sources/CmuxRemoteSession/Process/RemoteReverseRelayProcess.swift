/// A running dedicated SSH reverse-relay transport.
///
/// The coordinator owns this handle, terminates it during normal teardown, and
/// receives its fully drained diagnostic from the launcher at termination.
public protocol RemoteReverseRelayProcess: AnyObject, Sendable {
    /// Whether the transport process is still running.
    var isRunning: Bool { get }

    /// The process's exit status after termination.
    var terminationStatus: Int32 { get }

    /// Requests termination of the transport process.
    func terminate()
}
