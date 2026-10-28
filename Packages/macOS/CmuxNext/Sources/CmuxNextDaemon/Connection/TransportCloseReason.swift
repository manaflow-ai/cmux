import CmuxNextMetrics

/// Why a transport stopped.
public enum TransportCloseReason: Sendable, Equatable {
    /// `close()` was called locally.
    case closedByClient
    /// The daemon sent `daemon-shutdown`, then EOF.
    case daemonShutdown
    /// EOF, a read error, or a write the daemon's end refused (EPIPE, ECONNRESET).
    case lost(String)
    /// The app closed it on a fault it found itself: a message its reader could not cut, decode or route, or a
    /// write its writer could not make (a backlog the daemon did not read, a closed writer). The daemon may still
    /// run, so it is no daemon end.
    case appFault(String)

    /// The close as logs, disconnect events and connection errors name it.
    public var detail: String {
        switch self {
        case .closedByClient: "closed"
        case .daemonShutdown: "daemon shut down"
        case .lost(let text), .appFault(let text): text
        }
    }

    /// How a ready connection's end says its daemon ended (`stability.child_exit.daemon`, p09-observability-109):
    /// a `daemon-shutdown` first is a clean exit; an end without it is a signal (the app is not the daemon's parent,
    /// so no exit status says more). A close the app made, its own or on a fault it found, is no daemon exit.
    var daemonExit: HistogramID.ChildExit? {
        switch self {
        case .closedByClient, .appFault: nil
        case .daemonShutdown: .clean
        case .lost: .signal
        }
    }
}
