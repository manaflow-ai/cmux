/// Terminal signal used to race an external navigation against its deadline.
enum ExternalNavigationRaceResult: Sendable {
    case committed
    case timedOut
    case cancelled
    case failed
}
