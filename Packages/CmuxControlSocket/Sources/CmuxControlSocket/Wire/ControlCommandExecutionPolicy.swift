/// Where a v2 control command executes (was `SocketCommandExecutionPolicy`).
///
/// An isolation-intent value: the dispatcher consults it to decide whether a
/// method runs on the main actor or stays on the socket-worker thread.
public enum ControlCommandExecutionPolicy: Sendable, Equatable {
    /// The command must run on the main actor (UI/window/workspace state).
    case mainActor
    /// The command runs on the socket-worker thread (blocking or long-running
    /// work that must not occupy the main actor).
    case socketWorker
}
