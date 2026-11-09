import CmuxNextCompat

/// What the launcher tells app health about the session daemon (the shared health contract, part
/// `sessionDaemon`): read-only facts of each `server ensure`, never a decision. The kill, replace and
/// timeout rules stay the launcher's (DaemonLauncher+Replace, UnresponsiveOwnerWatch). Restore
/// progress is not read here: `DaemonRecovery.restoring` reports it (`AppHealth.noteDaemonRestoring(pid:)`).
extension DaemonLauncher {
    public enum HealthSignal: Sendable, Equatable {
        /// `server ensure` runs with no owner answering `server status`: it starts one.
        case started
        /// An owner answers (`server status` found it, or `server ensure` returned it).
        case ready(pid: Int32)
        /// `server ensure` failed or timed out: the owner it started did not become ready.
        case exited
    }

    private static let healthSink = Mutex<@Sendable (HealthSignal) -> Void>({ _ in })

    /// Receives every launcher's ``HealthSignal``s, on the thread that saw them. The App sets it once
    /// at launch to its app health feed (like `DaemonService.launchMark`); the default drops them.
    public static var health: @Sendable (HealthSignal) -> Void {
        get { healthSink.withLock { $0 } }
        set { healthSink.withLock { $0 = newValue } }
    }

    static func noteHealth(_ signal: HealthSignal) {
        health(signal)
    }
}
