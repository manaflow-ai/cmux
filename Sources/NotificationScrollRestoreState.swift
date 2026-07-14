/// The lifecycle of a notification-requested terminal viewport restore.
enum NotificationReplayRestoreContext {
    /// Boundary geometry may race a newer terminal row space before the first atomic restore.
    case provisional(NotificationScrollRestoreGeometry)
    /// Completed replay geometry retained for future notification activation.
    case stable(NotificationScrollRestoreGeometry)

    var geometry: NotificationScrollRestoreGeometry {
        switch self {
        case .provisional(let geometry), .stable(let geometry):
            geometry
        }
    }
}

enum NotificationScrollRestoreState {
    case inactive
    case armed(
        expectedStartBoundary: String,
        expectedEndBoundary: String,
        pendingPosition: TerminalNotificationScrollPosition?,
        attemptsRemaining: Int
    )
    case replaying(
        expectedBoundary: String,
        pendingPosition: TerminalNotificationScrollPosition?
    )
    /// Replay ended before authoritative geometry became readable.
    case replayCompletedAwaitingGeometry
    /// Retains the row space produced by a completed replay for late notification activation.
    case replayCompleted(geometry: NotificationScrollRestoreGeometry)
    case awaitingInitialGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    )
    /// Waits for terminal-owned geometry after the replay boundary.
    case awaitingPostReplayGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    )
    /// Restores against a stable replay-completion row space.
    case awaitingPostReplayRestore(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        replayContext: NotificationReplayRestoreContext
    )

    var pendingPosition: TerminalNotificationScrollPosition? {
        switch self {
        case .inactive, .replayCompletedAwaitingGeometry, .replayCompleted:
            nil
        case .armed(_, _, let pendingPosition, _):
            pendingPosition
        case .replaying(_, let pendingPosition):
            pendingPosition
        case .awaitingInitialGeometry(let position, _):
            position
        case .awaitingPostReplayGeometry(let position, _):
            position
        case .awaitingPostReplayRestore(let position, _, _):
            position
        }
    }
}
