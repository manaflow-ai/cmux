import Foundation

/// The authoritative state of a Cloud machine's demand-driven port scan.
enum CloudPortDiscoveryState: Hashable, Codable, Sendable {
    /// Ports have not been requested yet; expanding the Ports group starts a scan.
    case notRequested
    /// A scan is in flight. Existing port rows remain visible while it runs.
    case loading
    /// A completed scan found at least one reachable service.
    case available
    /// A completed scan found no service that cmux can reach.
    case empty(CloudPortDiscoveryEmptyReason)
    /// The scan or the route could not be used to produce a trustworthy result.
    case unavailable(CloudPortDiscoveryUnavailableReason)
    /// The last graph is retained, but a reconnect or refresh no longer proves it current.
    case stale
    /// The provider does not advertise Cloud port discovery or preview support.
    case unsupported

    /// Whether the Ports group should keep a status row after real port rows.
    var keepsStatusAlongsideRows: Bool {
        switch self {
        case .unavailable, .stale, .unsupported:
            return true
        case .notRequested, .loading, .available, .empty:
            return false
        }
    }

    /// Stable, nonlocalized value used by socket exports and diagnostics.
    var wireValue: String {
        switch self {
        case .notRequested: return "not_requested"
        case .loading: return "loading"
        case .available: return "available"
        case .empty(let reason): return "empty_\(reason.rawValue)"
        case .unavailable(let reason): return "unavailable_\(reason.rawValue)"
        case .stale: return "stale"
        case .unsupported: return "unsupported"
        }
    }
}
