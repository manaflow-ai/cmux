/// Owns the coupled control and application-lane lifetime of one admitted connection.
///
/// Construct one supervisor per admitted peer. The first child operation to
/// finish, or cancellation of ``run()``, cancels the sibling before the
/// connection and application lanes are closed in a stable order. Repeated
/// calls to ``run()`` are ignored so cleanup cannot run twice for one owner.
///
/// ```swift
/// let supervisor = CmxIrohAdmittedConnectionSupervisor(
///     runControl: { await serveControl() },
///     runApplicationLanes: { await serveApplicationLanes() },
///     closeConnection: { await connection.close() },
///     stopApplicationLanes: { await lanes.stop() }
/// )
/// await supervisor.run()
/// ```
public actor CmxIrohAdmittedConnectionSupervisor {
    private let runControl: @Sendable () async -> Void
    private let runApplicationLanes: @Sendable () async -> Void
    private let closeConnection: @Sendable () async -> Void
    private let stopApplicationLanes: @Sendable () async -> Void
    private var didRun = false

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
        runControl: @escaping @Sendable () async -> Void,
        runApplicationLanes: @escaping @Sendable () async -> Void,
        closeConnection: @escaping @Sendable () async -> Void,
        stopApplicationLanes: @escaping @Sendable () async -> Void
    ) {
        self.runControl = runControl
        self.runApplicationLanes = runApplicationLanes
        self.closeConnection = closeConnection
        self.stopApplicationLanes = stopApplicationLanes
    }

    /// Runs the connection until either child exits, then closes all owned work.
    public func run() async {
        guard !didRun else { return }
        didRun = true
        let runControl = runControl
        let runApplicationLanes = runApplicationLanes
        let closeConnection = closeConnection
        let stopApplicationLanes = stopApplicationLanes

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await runControl()
            }
            group.addTask {
                await runApplicationLanes()
            }
            _ = await group.next()
            group.cancelAll()
            await closeConnection()
            await stopApplicationLanes()
        }
    }
}
