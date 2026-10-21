/// A started `serve-web` process, as the service holds it.
public protocol VSCodeServeWebProcessHandle: AnyObject, Sendable {
    /// Whether the process is still running.
    var isRunning: Bool { get }
    /// Ends the process (SIGTERM). Safe to call more than once and from any thread.
    func terminate()
}
