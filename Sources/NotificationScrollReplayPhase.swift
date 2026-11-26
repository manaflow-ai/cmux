/// The replay lifecycle that determines which terminal geometry is authoritative.
enum NotificationScrollReplayPhase {
    case inactive
    case armed(expectedStartBoundary: String, expectedEndBoundary: String)
    case armedAfterExplicitInput(expectedStartBoundary: String, expectedEndBoundary: String)
    case replaying(expectedEndBoundary: String)
    case replayingAfterExplicitInput(expectedEndBoundary: String)
    case completedAwaitingGeometry
    case completed(NotificationScrollRestoreGeometry)
}
