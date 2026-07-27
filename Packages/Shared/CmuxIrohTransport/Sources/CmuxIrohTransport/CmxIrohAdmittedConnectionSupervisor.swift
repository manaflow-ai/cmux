/// Owns the coupled control and application-lane lifetime of one admitted connection.
///
/// Construct one supervisor per admitted peer. The first child operation to
/// finish, or cancellation of ``run()``, cancels the sibling before the
/// connection and application lanes are closed in a stable order. Repeated
/// calls to ``run()`` are ignored so cleanup cannot run twice for one owner.
///
/// ```swift
/// let supervisor = CmxIrohAdmittedConnectionSupervisor(
///     runControl: {
///         await serveControl()
///         return CmxIrohAdmittedConnectionExit(
///             lifecycle: .remoteClosed,
///             failure: .connectionClosed
///         )
///     },
///     runApplicationLanes: {
///         await serveApplicationLanes()
///         return CmxIrohAdmittedConnectionExit(
///             lifecycle: .applicationLaneFailed,
///             failure: .connectionClosed
///         )
///     },
///     closeConnection: { await connection.close() },
///     stopApplicationLanes: { await lanes.stop() }
/// )
/// let exit = await supervisor.run()
/// ```
public actor CmxIrohAdmittedConnectionSupervisor {
    private let runControl: @Sendable () async -> CmxIrohAdmittedConnectionExit
    private let runApplicationLanes: @Sendable () async -> CmxIrohAdmittedConnectionExit
    private let closeConnection: @Sendable () async -> Void
    private let stopApplicationLanes: @Sendable () async -> Void
    private var runTask: Task<CmxIrohAdmittedConnectionExit, Never>?

    /// Creates the sole lifetime owner for one admitted connection.
    ///
    /// - Parameters:
    ///   - runControl: Serves the authenticated control protocol until it ends
    ///     or is cancelled.
    ///   - runApplicationLanes: Accepts and serves post-admission application
    ///     lanes until it ends or is cancelled.
    ///   - closeConnection: Closes the complete peer connection and unblocks
    ///     outstanding stream operations.
    ///   - stopApplicationLanes: Cancels and joins every accepted application
    ///     lane after the connection starts closing.
    public init(
        runControl: @escaping @Sendable () async -> CmxIrohAdmittedConnectionExit,
        runApplicationLanes: @escaping @Sendable () async -> CmxIrohAdmittedConnectionExit,
        closeConnection: @escaping @Sendable () async -> Void,
        stopApplicationLanes: @escaping @Sendable () async -> Void
    ) {
        self.runControl = runControl
        self.runApplicationLanes = runApplicationLanes
        self.closeConnection = closeConnection
        self.stopApplicationLanes = stopApplicationLanes
    }

    /// Runs until either child exits, closes owned work, and returns that first exit reason.
    public func run() async -> CmxIrohAdmittedConnectionExit {
        if let runTask { return await runTask.value }
        let runControl = runControl
        let runApplicationLanes = runApplicationLanes
        let closeConnection = closeConnection
        let stopApplicationLanes = stopApplicationLanes

        let task = Task {
            await withTaskGroup(
                of: CmxIrohAdmittedConnectionExit.self,
                returning: CmxIrohAdmittedConnectionExit.self
            ) { group in
                group.addTask {
                    await runControl()
                }
                group.addTask {
                    await runApplicationLanes()
                }
                let firstExit = await group.next() ?? CmxIrohAdmittedConnectionExit(
                    lifecycle: .explicitlyInvalidated,
                    failure: .none
                )
                group.cancelAll()
                await closeConnection()
                await stopApplicationLanes()
                return firstExit
            }
        }
        runTask = task
        return await withTaskCancellationHandler(
            operation: {
                await task.value
            },
            onCancel: {
                task.cancel()
            }
        )
    }
}
