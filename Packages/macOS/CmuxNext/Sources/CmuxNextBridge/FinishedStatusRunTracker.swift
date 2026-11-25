public import CmuxNextDaemon
import CmuxNextWindowRules

/// Finds the `cmux status run`s that finish between two looks at the
/// workspaces' status entries. A run counts only when this client saw it
/// busy first, so a finished entry that is already there (a relaunch, a
/// reconnect while its badge shows) is not news, and a finished entry that
/// stays (another entry of its workspace changed) counts once. A run whose
/// entry goes away while busy (its CLI was killed) never counts. The rule is
/// Rust's (cmux-window-rules `status_alerts::update_runs`, op
/// `window_notifications_status_runs`); this keeps the busy runs between looks.
public struct FinishedStatusRunTracker: Sendable {
    private struct Run: Codable, Hashable, Sendable {
        var workspace: String
        var key: String
    }

    /// The runs busy at the last update.
    private var running: [Run] = []

    public init() {}

    /// The runs that finished since the last update; remembers the busy ones for the next.
    ///
    /// - Parameter statuses: Every workspace's status now.
    /// - Returns: The runs this update shows finished, in the statuses' order.
    public mutating func update(_ statuses: [WorkspaceStatus]) -> [FinishedStatusRun] {
        struct Entry: Encodable {
            var key: String, state: String?, text: String, targetTerminal: String?, exitCode: Int?, durationMs: UInt64?
        }
        struct Status: Encodable { var workspace: String, entries: [Entry] }
        struct Request: Encodable { var running: [Run], statuses: [Status] }
        struct Finished: Decodable {
            var workspace: String, key: String, label: String, terminal: String?, succeeded: Bool, exitCode: Int?, durationMs: UInt64?
        }
        struct Reply: Decodable { var finished: [Finished], running: [Run] }
        let request = Request(running: running, statuses: statuses.map { status in
            Status(workspace: status.workspaceID.rawValue, entries: status.entries.map { entry in
                Entry(key: entry.key, state: entry.state, text: entry.text, targetTerminal: entry.targetTerminal,
                      exitCode: entry.exitCode, durationMs: entry.durationMs)
            })
        })
        // An FFI without the op answers nothing: no run finished, and the busy ones stay as they were.
        guard let reply = WindowRules().call("window_notifications_status_runs", request, as: Reply.self) else { return [] }
        running = reply.running
        return reply.finished.map { run in
            FinishedStatusRun(workspace: ResourceID(rawValue: run.workspace), key: run.key, label: run.label, terminal: run.terminal,
                              succeeded: run.succeeded, exitCode: run.exitCode, durationMs: run.durationMs)
        }
    }
}
