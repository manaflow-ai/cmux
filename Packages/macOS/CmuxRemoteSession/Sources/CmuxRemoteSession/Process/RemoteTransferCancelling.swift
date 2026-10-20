/// A live cancellation token for a long-running remote file transfer,
/// inverted from the app's `TerminalImageTransferOperation` so the package
/// can honor drag-and-drop cancellation without importing the app type.
///
/// The app conformer owns the synchronization; all members may be called from
/// the coordinator's serial queue or the process runner's blocking context.
public protocol RemoteTransferCancelling: Sendable {
    /// True once the operation was cancelled.
    var isCancelled: Bool { get }
    /// The error the owning operation uses to represent cancellation
    /// (`TerminalImageTransferExecutionError.cancelled` app-side); thrown and
    /// delivered through completion handlers exactly where the legacy
    /// controller threw the concrete error.
    var cancellationError: any Error { get }
    /// Throws `cancellationError` when already cancelled.
    func throwIfCancelled() throws
    /// Installs the handler to run on cancellation (invoked immediately when
    /// already cancelled); at most one handler is active at a time.
    func installCancellationHandler(_ handler: @escaping () -> Void)
    /// Removes the active cancellation handler, if any.
    func clearCancellationHandler()
}
