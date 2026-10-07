/// The latest path snapshot, if known. `DirectReachabilityMonitor`
/// implements it; tests pass a fixed one.
public protocol DirectRouteProvider: Sendable {
    var currentSnapshot: DirectPathSnapshot? { get }
}
