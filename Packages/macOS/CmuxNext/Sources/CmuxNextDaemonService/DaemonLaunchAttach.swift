/// How the local daemon's launch connect found its daemon (``DaemonService/launchAttach``).
///
/// The daemon is the browser process of cmux's process model (plans/cmux-next/chrome-parity/p01-process.md, rule 19):
/// it keeps every terminal, its output and its children while the app is gone, so a launch after the app alone ended
/// (`kill -9`, a crash) attaches to it and draws what it holds instead of starting over.
public enum DaemonLaunchAttach: Sendable, Equatable {
    /// The launch connect has not attached a connection yet, or this service has no launch connect (a remote
    /// machine, a test that starts without connect milestones).
    case pending
    /// The launch attached a daemon that was running before it: its terminals went on while the app was gone.
    case reattached
    /// The launch started the daemon: none ran (a cold start), or the running one handed off to the bundled build.
    case started
}
