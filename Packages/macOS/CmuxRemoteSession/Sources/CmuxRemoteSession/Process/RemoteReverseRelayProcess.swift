public import Foundation

/// A running dedicated SSH reverse-relay transport.
///
/// The coordinator owns this handle, terminates it during normal teardown, and
/// uses its stderr stream to diagnose startup and later transport failures.
public protocol RemoteReverseRelayProcess: AnyObject, Sendable {
    /// The process's standard-error pipe.
    var stderrPipe: Pipe { get }

    /// Whether the transport process is still running.
    var isRunning: Bool { get }

    /// The process's exit status after termination.
    var terminationStatus: Int32 { get }

    /// Waits for an immediate startup failure and returns its best diagnostic.
    ///
    /// - Parameter gracePeriod: Maximum time to wait for an early process exit.
    /// - Returns: The best failure line when the process exits, or `nil` when it
    ///   remains running through the grace period.
    func startupFailureDetail(gracePeriod: TimeInterval) -> String?

    /// Requests termination of the transport process.
    func terminate()
}
