/// Starts `serve-web` processes. ``VSCodeServeWebProcessLauncher`` runs the real binary; tests
/// pass a fake.
public protocol VSCodeServeWebLaunching: Sendable {
    /// Starts `launch` and returns once the server printed its Web UI URL.
    ///
    /// Cancelling the calling task ends a process that is still starting.
    /// - Parameter launch: The process to start.
    /// - Returns: The ready server.
    /// - Throws: ``VSCodeServeWebError`` when the process cannot start, exits first or misses the deadline.
    func start(_ launch: VSCodeServeWebLaunch) async throws -> VSCodeServeWebStarted
}
