import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    case listWindows
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    /// A per-window `refresh-client -C '@id:WxH'` — an %error reply means
    /// the server predates the form and sizing falls back session-wide.
    case perWindowSize(Int)
    case other
}
