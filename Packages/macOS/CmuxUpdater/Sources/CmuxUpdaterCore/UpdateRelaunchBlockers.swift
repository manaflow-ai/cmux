/// What an update relaunch would interrupt right now, as reported by the host app.
public struct UpdateRelaunchBlockers: Equatable, Sendable {
    /// Coding agents that are mid-turn. They finish on their own, so the gate waits for them.
    public var busyAgentCount: Int
    /// Other foreground commands in local terminals (a dev server, a build). They may never
    /// exit, so the gate holds the relaunch until the user chooses Install Now.
    public var runningCommandCount: Int
    /// Hardware input happened during the quiet window. Only automatic installs wait for it to
    /// clear: an install the user asked for is itself recent input.
    public var userInputActive: Bool
    /// The host cannot confirm the daemon/session mirror yet. Only automatic installs wait for
    /// it, and only until the daemon timeout.
    public var daemonStateUnavailable: Bool

    /// How long hardware input must be quiet before an automatic relaunch, unless the host sets
    /// its own (`updates.idleInstallQuietSeconds`).
    public static let quietInputPeriod: Duration = .seconds(60)

    /// Nothing would be interrupted.
    public static let empty = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0)
    /// A conservative hold used before the host has a trustworthy daemon mirror.
    public static let daemonUnavailable = UpdateRelaunchBlockers(
        busyAgentCount: 0, runningCommandCount: 0, daemonStateUnavailable: true)

    /// Creates a blocker report.
    public init(busyAgentCount: Int, runningCommandCount: Int, userInputActive: Bool = false,
                daemonStateUnavailable: Bool = false) {
        self.busyAgentCount = busyAgentCount
        self.runningCommandCount = runningCommandCount
        self.userInputActive = userInputActive
        self.daemonStateUnavailable = daemonStateUnavailable
    }

    /// Whether the relaunch would interrupt nothing.
    public var isEmpty: Bool {
        busyAgentCount == 0 && runningCommandCount == 0 && !userInputActive && !daemonStateUnavailable
    }

    /// The blockers that hold an install the user asked for (a click, Install Now, Restart Now):
    /// the quiet-input and daemon-mirror holds apply only to automatic installs.
    public var forUserInstall: UpdateRelaunchBlockers {
        UpdateRelaunchBlockers(busyAgentCount: busyAgentCount, runningCommandCount: runningCommandCount)
    }

    /// Whether the relaunch may proceed with these blockers after waiting `waited`, with the daemon
    /// mirror unconfirmed for the last `daemonUnavailableFor`. An install the user asked for
    /// (`automatic == false`) ignores the quiet-input and daemon-mirror holds; an automatic one
    /// stops waiting for anything once it has waited `automaticWaitCap`.
    package func permitsRelaunch(
        automatic: Bool,
        waited: Duration,
        daemonUnavailableFor: Duration,
        agentTimeout: Duration,
        daemonUnavailableTimeout: Duration,
        automaticWaitCap: Duration
    ) -> Bool {
        guard automatic else {
            if runningCommandCount > 0 { return false }
            if busyAgentCount > 0 { return waited >= agentTimeout }
            return true
        }
        if waited >= automaticWaitCap { return true }
        if daemonStateUnavailable, daemonUnavailableFor < daemonUnavailableTimeout { return false }
        if runningCommandCount > 0 { return false }
        if userInputActive { return false }
        if busyAgentCount > 0 { return false }
        return true
    }
}
