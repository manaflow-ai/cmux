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
    case awaitingInitialGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    )
    case awaitingPostReplayGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        unaddressableGeometryUpdatesRemaining: Int
    )

    var pendingPosition: TerminalNotificationScrollPosition? {
        switch self {
        case .inactive:
            nil
        case .armed(_, _, let pendingPosition, _):
            pendingPosition
        case .replaying(_, let pendingPosition):
            pendingPosition
        case .awaitingInitialGeometry(let position, _),
             .awaitingPostReplayGeometry(let position, _, _):
            position
        }
    }
}
