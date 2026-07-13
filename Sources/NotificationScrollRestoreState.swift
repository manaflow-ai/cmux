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
    /// Waits for renderer geometry that confirms or corrects the boundary-time restore.
    case awaitingPostReplayGeometry(
        position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        provisionalTopRow: Int?
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
