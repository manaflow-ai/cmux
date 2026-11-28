public import Foundation

/// App logs: `apps-logs` with follow, then `apps-log` events.
extension AppsClient {
    func appendLog(_ app: String, level: String, message: String, date: Date?) {
        var lines = logs[app] ?? []
        lines.append(AppLogLine(id: nextLog, date: date, level: level, message: message))
        nextLog += 1
        if lines.count > Self.logLimit { lines.removeFirst(lines.count - Self.logLimit) }
        setLogs(app, lines)
    }

    /// Loads an app's log and follows it (`apps-logs {follow: true}`); lines
    /// that arrive while the load is in flight are kept after it. Followed
    /// again after a reconnect.
    public func followLogs(_ app: String) {
        followed.insert(app)
        guard availability.isAvailable else { return }
        let firstLive = nextLog
        // task-owner: one log load; apps-log events follow
        Task { [weak self, transport] in
            guard let loaded = try? await transport.logs(app: app, follow: true), let self else { return }
            let live = (logs[app] ?? []).filter { $0.id >= firstLive }
            var lines = loaded.map { line in
                defer { nextLog += 1 }
                return AppLogLine(id: nextLog, date: line.date, level: line.level, message: line.message)
            } + live
            if lines.count > Self.logLimit { lines.removeFirst(lines.count - Self.logLimit) }
            setLogs(app, lines)
        }
    }
}
