/// The presence socket's timing, apart from the socket: ``PresenceListener`` waits on it and
/// ``LiveCoordinator`` redials the links by it, and the network-flap matrix
/// (ConnectivityMatrixTests) replays it in the Linux test build, which has neither type.
enum PresenceTiming {
    /// Poll interval while the socket is down.
    static let pollInterval: Duration = .seconds(20)
    static let helloTimeout: Duration = .seconds(10)
    /// Presence down at least this long before its return redials the links.
    static let outageMin: Duration = .seconds(3)

    /// The socket's retry after `failures` failures in a row: 2 s, 3 s, then every 5 s
    /// for about five minutes, then the poll interval. Its hello after an outage is what
    /// tells the links the network is back when iOS reports no path change, so it
    /// retries as often as the links do (was 2, 4, 8, then 20 s).
    static func retryDelay(afterFailures failures: Int) -> Duration {
        switch failures {
        case ..<2: .seconds(2)
        case 2: .seconds(3)
        case ..<60: .seconds(5)
        default: pollInterval
        }
    }
}
