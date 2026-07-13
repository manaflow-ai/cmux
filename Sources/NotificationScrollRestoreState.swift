/// The lifecycle of a notification-requested terminal viewport restore.
enum NotificationScrollRestoreState {
    case inactive
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
        attemptsRemaining: Int
    )

    var pendingPosition: TerminalNotificationScrollPosition? {
        switch self {
        case .inactive:
            nil
        case .replaying(_, let pendingPosition):
            pendingPosition
        case .awaitingInitialGeometry(let position, _),
             .awaitingPostReplayGeometry(let position, _):
            position
        }
    }
}
