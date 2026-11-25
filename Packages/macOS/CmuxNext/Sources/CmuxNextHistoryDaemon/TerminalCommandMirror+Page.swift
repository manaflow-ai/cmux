public import CmuxNextDaemon
public import CmuxNextHistory
public import Foundation

extension TerminalCommandMirror {
    /// Applies one `list-terminal-commands` page read after `after` (``apply(_:version:truncated:after:expiredThrough:)``),
    /// dropping the rows older than the page's retention. False: the mirror was reset, read again from the first row.
    public nonisolated mutating func apply(_ page: ListTerminalCommandsRequest.Response, after: UInt64?, now: Date = Date()) -> Bool {
        let expired = now.addingTimeInterval(-TimeInterval(page.retentionDays) * 86_400)
        return apply(page.commands.compactMap { Self.command($0, machine: machine) }, version: page.version,
                     truncated: page.truncated, after: after, expiredThrough: expired)
    }

    /// The command a daemon row names; nil for a row whose id or start time does not parse.
    public nonisolated static func command(_ row: TerminalCommandRow, machine: String) -> TerminalCommand? {
        guard let id = UInt64(row.id), let started = Int64(row.startedAtMs) else { return nil }
        return TerminalCommand(id: id, machine: machine, terminal: row.terminalID, command: row.command, cwd: row.cwd,
                               exitCode: row.exitCode, startedAt: Date(timeIntervalSince1970: TimeInterval(started) / 1000),
                               duration: Double(row.durationMs).map { $0 / 1000 })
    }
}
