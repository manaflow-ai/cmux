public import CmuxNextDaemon

/// The reply of a command that makes a terminal tab, and the watch of its terminal's start when the
/// daemon answered before the host was up (`terminal-async-start-v1`, ``TerminalStartWatch``).
///
/// The reply ends the command's work: the intent settles, the daemon's tab shows, the window's keys,
/// focus and sizing resolve. The start's outcome is a separate follow-up (``outcome()``) that only
/// reports a failure (the daemon rolls back what the command made), as Chromium's
/// `ChildProcessLauncher::Client::OnProcessLaunchFailed` reaches a tab that already shows.
public struct StartingTerminal: Sendable {
    /// The command's reply.
    public let created: SurfaceCreated
    /// The watch of its terminal's start; nil when the reply came after the start.
    let watch: TerminalStartWatch?

    /// A reply that came after its terminal started (nothing to follow).
    public init(created: SurfaceCreated) {
        self.init(created: created, watch: nil)
    }

    /// The reply, keeping `watch` only when the reply left the start running (`starting: true`).
    init(created: SurfaceCreated, watch: TerminalStartWatch?) {
        self.created = created
        if created.starting == true {
            self.watch = watch
        } else {
            watch?.cancel()
            self.watch = nil
        }
    }

    /// Whether the start still runs after the reply.
    public var isStarting: Bool { watch != nil }

    /// How the start ended, bounded by the start deadline (``TerminalStartWatch/outcome()``);
    /// ``TerminalStartOutcome/started`` for a reply that came after the start.
    public func outcome() async -> TerminalStartOutcome {
        await watch?.outcome() ?? .started
    }

    /// Stops following the start (the tab closed before the reply came).
    func cancel() {
        watch?.cancel()
    }
}
