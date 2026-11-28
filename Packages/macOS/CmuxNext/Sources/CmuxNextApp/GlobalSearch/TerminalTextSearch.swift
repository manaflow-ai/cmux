import CmuxNextDaemon
import Foundation

/// Reads terminal text for Search All Windows: a terminal's retained
/// history and its screen, from its daemon, so tabs no window shows are read
/// too.
nonisolated enum TerminalTextSearch {
    /// One terminal to read.
    nonisolated struct Target: Sendable {
        let tabID: String
        let surface: SurfaceID
        let connection: DaemonConnection
    }

    /// History rows read per terminal (the old app captured 4,000).
    static let historyRows: UInt32 = 4_000
    /// Per request; a busy or unreachable daemon's terminals count as unread.
    static let timeout: Duration = .seconds(2)
    /// Terminals read at once, so a search does not flood the connections
    /// that also carry typing and output.
    static let concurrentReads = 8

    /// The last `historyRows` history rows, then the screen; nil when the
    /// daemon did not answer.
    static func lines(of target: Target) async -> [String]? {
        let connection = target.connection, surface = target.surface
        var lines: [String] = []
        if let total = try? await connection.request(ReadScrollbackRequest(surface: surface, start: 0, count: 0), timeout: timeout).total,
           total > 0 {
            let count = min(total, historyRows)
            let page = try? await connection.request(ReadScrollbackRequest(surface: surface, start: total - count, count: count),
                                                     timeout: timeout)
            lines = page?.lines ?? []
        }
        guard let screen = try? await connection.request(ReadScreenRequest(surface: surface), timeout: timeout) else { return nil }
        return lines + screen.text.components(separatedBy: "\n")
    }
}
