/// Drains a spawned diff-viewer process's stdout/stderr without unbounded
/// buffering, mirroring the app target's `ProcessOutputCollector` contract.
///
/// ``DiffViewerLaunchService`` only needs the byte count of the collected
/// output (logged in DEBUG); the concrete collector remains an app-target type
/// shared by other launchers, so the service receives one through an injected
/// factory behind this seam and never names it.
public protocol DiffViewerProcessOutputDraining: AnyObject, Sendable {
    /// Begins reading both pipes incrementally.
    func start()

    /// Stops reading, drains any remainder, and returns the collected output.
    @discardableResult
    func finish() -> String

    /// Tears down readers without draining (used when the launch throws).
    func cancel()
}
