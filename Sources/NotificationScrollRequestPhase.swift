/// The transient notification viewport request that runs within the replay lifecycle.
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
