import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    case listWindows
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    /// A generic command whose `%begin`/`%end` reply body is returned to the
    /// caller (the linked-view coordinator runs `list-sessions`/`list-windows -a`
    /// over the single control stream because MaxSessions=1 forbids a second
    /// concurrent ssh for one-shots).
    case query(UUID)
    case other
}
