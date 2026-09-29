import CmuxNextDaemon
import Foundation

// cmux-tui commands the GUI does not issue, so CmuxNextDaemon has no
// request types for them (cmux-tui/spec/commands.md).

/// `read-screen`: plain-text viewport of a PTY surface.
struct CompatReadScreenRequest: DaemonRequest {
    struct Response: Decodable, Sendable { var text: String }
    static let command = "read-screen"
    var surface: SurfaceID
}

/// `read-scrollback`: one page of retained history rows (styled runs),
/// flattened here to text lines.
struct CompatReadScrollbackRequest: DaemonRequest {
    struct Response: Decodable, Sendable {
        struct Row: Decodable, Sendable {
            struct Run: Decodable, Sendable { var text: String }
            var runs: [Run]
        }
        var rows: [Row]
        var start: UInt32
        var total: UInt32

        var text: String {
            rows.map { row in
                let line = row.runs.map(\.text).joined()
                return String(line.reversed().drop(while: { $0 == " " }).reversed())
            }.joined(separator: "\n")
        }
    }
    static let command = "read-scrollback"
    var surface: SurfaceID
    var start: UInt32
    var count: UInt32
}

/// `clear-history`: drops retained scrollback.
struct CompatClearHistoryRequest: DaemonRequest {
    typealias Response = EmptyResponse
    static let command = "clear-history"
    var surface: SurfaceID
}
