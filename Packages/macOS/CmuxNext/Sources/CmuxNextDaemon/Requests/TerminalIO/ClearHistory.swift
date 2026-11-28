import Foundation

/// `clear-history`: Cmd-K (Clear Screen and Scrollback) in the daemon, which owns the terminal
/// state. The daemon erases the primary screen's rows before the shell prompt and the retained
/// history, and every attached view gets the same erase; an alternate-screen program is left
/// untouched. It fails without a change when it cannot restore the cursor exactly.
public struct ClearHistoryRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {}
    public static let command = "clear-history"
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}
