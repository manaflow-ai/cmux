enum CameraJournalLockRaceEvent: Equatable, Sendable {
    case contended
    case scanCompleted
    case scanFailed(String)
    case timedOut
}
