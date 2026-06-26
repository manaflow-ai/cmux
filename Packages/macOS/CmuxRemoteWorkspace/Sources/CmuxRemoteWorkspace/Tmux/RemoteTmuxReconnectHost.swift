/// Read/write seam that ``RemoteTmuxReconnectController`` uses to drive its owning
/// `tmux -CC` control connection without referencing the app-only connection-state
/// machine, the live respawn, or the app's diagnostics ring. The connection conforms
/// and injects itself via ``RemoteTmuxReconnectController/attach(host:)``.
///
/// Every member is plain (`Bool` phase check, a respawn trigger, a `String` event), so
/// the reconnect-backoff sub-model lives in this package while the connection-state
/// transitions, `notifyExit`, and the actual ssh respawn stay app-side.
@MainActor
public protocol RemoteTmuxReconnectHost: AnyObject {
    /// `true` while the connection is in the `.reconnecting` phase. A scheduled
    /// backoff attempt only fires the respawn while this holds, so a deliberate
    /// `stop()` or a genuine end that raced the sleep cancels the attempt.
    var isReconnecting: Bool { get }

    /// Re-spawns the ssh control client for one reconnect attempt (always
    /// attach-only). The connection owns the respawn (it touches the app-only spawn
    /// path); a spawn failure re-arms the backoff by calling
    /// ``RemoteTmuxReconnectController/scheduleAttempt()``.
    func performReconnectAttempt()

    /// Records a reconnect lifecycle event into the connection's diagnostics ring
    /// (surfaced through `remote.tmux.state`), keeping the diagnostics owner app-side.
    func recordReconnectEvent(_ message: String)
}
