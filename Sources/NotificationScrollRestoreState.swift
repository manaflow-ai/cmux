/// Replay authority and the transient notification request are orthogonal, but
/// this aggregate keeps both under one `GhosttySurfaceScrollView` owner.
struct NotificationScrollRestoreState {
    var replay: NotificationScrollReplayPhase = .inactive
    var request: NotificationScrollRequestPhase = .idle

    var pendingPosition: TerminalNotificationScrollPosition? {
        request.position
    }
}

enum NotificationScrollReplayPhase {
    case inactive
    case armed(expectedStartBoundary: String, expectedEndBoundary: String)
    case replaying(expectedEndBoundary: String)
    case completedAwaitingGeometry
    case completed(NotificationScrollRestoreGeometry)
}

enum NotificationScrollRequestPhase {
    case idle
    case waitingForReplay(position: TerminalNotificationScrollPosition, attemptsRemaining: Int)
    case awaitingInitialGeometry(position: TerminalNotificationScrollPosition, attemptsRemaining: Int)
    case awaitingPostReplayRestore(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        replayContext: NotificationReplayRestoreContext
    )

    var position: TerminalNotificationScrollPosition? {
        switch self {
        case .idle:
            nil
        case .waitingForReplay(let position, _),
             .awaitingInitialGeometry(let position, _),
             .awaitingPostReplayRestore(let position, _, _):
            position
        }
    }
}
