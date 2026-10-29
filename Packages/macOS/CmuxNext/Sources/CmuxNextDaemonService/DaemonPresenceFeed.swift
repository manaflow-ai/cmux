public import CmuxNextDaemon
public import CmuxNextWakeups

/// Feeds the app's one ``ConnectionPresence`` from its shown windows while it lives.
/// The composition root makes one, keeps it for the app's lifetime and hands ``presence`` to every
/// machine's ``DaemonService``.
@MainActor public final class DaemonPresenceFeed {
    /// What every daemon heartbeat follows.
    public let presence: ConnectionPresence
    private let shown: ShownWindowsObservation

    public init(windows: ShownWindows) {
        let presence = ConnectionPresence(shown: windows.anyShown)
        self.presence = presence
        shown = windows.observe { presence.update(shown: $0) }
    }
}
