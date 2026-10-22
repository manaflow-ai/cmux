import CmuxNextCompat
import Foundation
import Network
import os

/// Hands a stale acpmux daemon off at a quiet moment (``AcpmuxVersionHandoff``): while one of
/// its sessions runs a turn or waits on a permission, the daemon keeps running, and the app
/// watches its sessions (`_acpmux/watch`). At the first turn end, permission answer, status
/// change, or the end of that connection, the host looks again (a reconnect's lookup), and
/// hands it off if it is quiet now, or watches again. No timer and no polling: each look follows
/// an event from the daemon. A daemon with agent hosts that has waited past `cap` is handed off
/// at the next look anyway: its agents keep running under their hosts and the new daemon adopts
/// their turns.
nonisolated final class AcpmuxQuietHandoff: Sendable {
    static let shared = AcpmuxQuietHandoff(clock: ContinuousClock())

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// The `_acpmux/session_changed` kinds after which a busy daemon may be quiet.
    static let endsBusyKinds: Set<String> = [
        "turn_end", "turn_result", "turn_error", "permission_decision", "permission_resolved", "status", "purged",
    ]

    let cap: Duration
    private let elapsed: @Sendable () -> Duration

    private struct Pending {
        var since: Duration
        var watching = false
    }

    /// By `<home>|<pid>`.
    private let pending = Mutex<[String: Pending]>([:])

    init<C: Clock>(clock: C, cap: Duration = .seconds(600)) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.cap = cap
    }

    /// Whether daemon `pid` of `home` was first kept busy at least `cap` ago.
    func overdue(home: String, pid: Int32) -> Bool {
        let now = elapsed()
        return pending.withLock { $0["\(home)|\(pid)"].map { now - $0.since >= cap } ?? false }
    }

    /// Notes that daemon `pid` of `home` was kept because it is busy; the first time starts the wait.
    func deferred(home: String, pid: Int32) {
        let now = elapsed()
        pending.withLock { pending in
            if pending["\(home)|\(pid)"] == nil { pending["\(home)|\(pid)"] = Pending(since: now) }
        }
    }

    /// Runs `recheck` after the next session change of daemon `pid` that can end its busy
    /// moment, or when its connection ends. One watch per daemon at a time.
    func waitForQuiet(socketPath: String, home: String, pid: Int32, recheck: @escaping @Sendable () async -> Void) {
        let key = "\(home)|\(pid)"
        let now = elapsed()
        let starts = pending.withLock { pending -> Bool in
            var entry = pending[key] ?? Pending(since: now)
            guard !entry.watching else { return false }
            entry.watching = true
            pending[key] = entry
            return true
        }
        guard starts else { return }
        Self.logger.info("acpmux \(pid) is stale but busy; handing it off when its sessions are quiet")
        // task-owner: one per stale busy daemon; it ends at that daemon's next session change or when its connection closes
        Task.detached {
            await Self.nextChange(socketPath: socketPath)
            self.pending.withLock { $0[key]?.watching = false }
            await recheck()
        }
    }

    /// Whether no session in a `_acpmux/sessions` reply has a running turn, a waiting
    /// permission or a move under way. A peer's session runs on that peer and does not count.
    /// A reply this build cannot read is not quiet.
    static func quiet(sessions: Any?) -> Bool {
        guard let sessions = sessions as? [[String: Any]] else { return false }
        return sessions.allSatisfy { session in
            if session["peer"] is String { return true }
            let turn = session["turn"].map { !($0 is NSNull) } ?? false
            let pending = (session["pendingPermissions"] as? NSNumber)?.intValue ?? 0
            let status = session["status"] as? String
            let moving = (session["moving"] as? Bool) ?? false
            return !turn && pending == 0 && status != "running" && status != "waiting" && !moving
        }
    }

    /// Asks the daemon on `socketPath` whether its sessions are quiet; false when it cannot answer.
    @concurrent static func quiet(socketPath: String) async -> Bool {
        let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/sessions",
                                                        deadline: .seconds(5), limit: 64 << 20)
        return quiet(sessions: result?["sessions"])
    }

    /// Whether `line` is a `_acpmux/session_changed` of one of this daemon's own sessions whose
    /// kind can end a busy moment (``endsBusyKinds``).
    static func endsBusy(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["method"] as? String == "_acpmux/session_changed",
              let params = object["params"] as? [String: Any], params["peer"] == nil,
              let kind = params["kind"] as? String else { return false }
        return endsBusyKinds.contains(kind)
    }

    /// Whether `line` is the JSON-RPC reply to request `id`.
    static func isReply(_ line: Data, id: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return (object["id"] as? NSNumber)?.intValue == id && object["method"] == nil
    }

    /// Returns at the daemon's next session change that can end a busy moment, or when its
    /// connection ends or fails. `_acpmux/watch` with `limit: 1` keeps its first reply small.
    @concurrent static func nextChange(socketPath: String) async {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        let transport = AcpmuxSocketTransport(connection: connection)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-agent-pane", "version": "1"], "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true, "limit": 1]]
        do {
            try await transport.start()
            let payload = try JSONSerialization.data(withJSONObject: initialize) + Data([0x0A])
                + JSONSerialization.data(withJSONObject: watch) + Data([0x0A])
            try await transport.send(payload)
            var buffer = Data()
            // Each pass awaits socket data; EOF or an error ends it.
            while let chunk = try await transport.receive() {
                buffer += chunk
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if endsBusy(line) { return }
                    // An event between the caller's quiet check and this watch is not replayed:
                    // once the watch is on, ask once more.
                    if isReply(line, id: 2), await quiet(socketPath: socketPath) { return }
                }
                if buffer.count > 64 << 20 { return }
            }
        } catch {
            logger.info("acpmux quiet watch ended: \(String(describing: error), privacy: .public)")
        }
    }
}
