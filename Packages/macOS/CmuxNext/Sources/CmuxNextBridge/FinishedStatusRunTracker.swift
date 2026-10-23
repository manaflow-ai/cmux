public import CmuxNextDaemon

/// Finds the `cmux status run`s that finish between two looks at the
/// workspaces' status entries. A run counts only when this client saw it
/// busy first, so a finished entry that is already there (a relaunch, a
/// reconnect while its badge shows) is not news, and a finished entry that
/// stays (another entry of its workspace changed) counts once. A run whose
/// entry goes away while busy (its CLI was killed) never counts. Pure.
public struct FinishedStatusRunTracker: Sendable {
    private struct Run: Hashable, Sendable {
        var workspace: ResourceID
        var key: String
    }

    /// The key prefix of the entries `cmux status run` writes (`run:<pid>`).
    static let keyPrefix = "run:"

    /// The runs busy at the last update.
    private var running: Set<Run> = []

    public init() {}

    /// The runs that finished since the last update; remembers the busy ones for the next.
    ///
    /// - Parameter statuses: Every workspace's status now.
    /// - Returns: The runs this update shows finished, in the statuses' order.
    public mutating func update(_ statuses: [WorkspaceStatus]) -> [FinishedStatusRun] {
        var finished: [FinishedStatusRun] = []
        var busy: Set<Run> = []
        for status in statuses {
            for entry in status.entries where entry.key.hasPrefix(Self.keyPrefix) {
                let run = Run(workspace: status.workspaceID, key: entry.key)
                if entry.state == "busy" {
                    busy.insert(run)
                } else if entry.state == "success" || entry.state == "error", running.contains(run) {
                    finished.append(FinishedStatusRun(workspace: status.workspaceID, key: entry.key, label: entry.text,
                                                      terminal: entry.targetTerminal, succeeded: entry.state == "success",
                                                      exitCode: entry.exitCode, durationMs: entry.durationMs))
                }
            }
        }
        running = busy
        return finished
    }
}
