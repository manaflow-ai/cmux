/// Replay authority and the transient notification request are orthogonal, but
/// this aggregate keeps both under one `GhosttySurfaceScrollView` owner.
struct NotificationScrollRestoreState {
    var replay: NotificationScrollReplayPhase = .inactive
    var request: NotificationScrollRequestPhase = .idle

    var pendingPosition: TerminalNotificationScrollPosition? {
        request.position
    }
}
