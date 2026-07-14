/// The lifecycle of a notification-requested terminal viewport restore.
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
    /// Retains the row space produced by a completed replay for late notification activation.
    case replayCompleted(geometry: NotificationScrollRestoreGeometry)
    case awaitingInitialGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    )
    /// Waits for terminal-owned geometry after the replay boundary.
    case awaitingPostReplayGeometry(
        position: TerminalNotificationScrollPosition?,
        attemptsRemaining: Int,
        replayCompletionGeometry: NotificationScrollRestoreGeometry?
    )

    var pendingPosition: TerminalNotificationScrollPosition? {
        switch self {
        case .inactive, .replayCompleted:
            nil
        case .armed(_, _, let pendingPosition, _):
            pendingPosition
        case .replaying(_, let pendingPosition):
            pendingPosition
        case .awaitingInitialGeometry(let position, _):
            position
        case .awaitingPostReplayGeometry(let position, _, _):
            position
        }
    }
}
