import CmuxNextDaemon
import Foundation

// cmux-tui commands only the compatibility layer issues, so CmuxNextDaemon
// has no request types for them (cmux-tui/spec/commands.md). The text reads
// (`ReadScreenRequest`, `ReadScrollbackRequest`) are shared with the App.

/// `clear-history`: drops retained scrollback.
struct CompatClearHistoryRequest: DaemonRequest {
    typealias Response = EmptyResponse
    static let command = "clear-history"
    var surface: SurfaceID
}
