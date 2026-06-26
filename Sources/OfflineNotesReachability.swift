import Foundation

/// Observes whether the machine currently has network connectivity and reports
/// changes. Abstracted behind a protocol so the store can be driven by a fake
/// in tests instead of the real `NWPathMonitor` (see ``OfflineNotesNetworkReachability``).
@MainActor
protocol OfflineNotesReachabilityMonitoring: AnyObject {
    /// Best current knowledge of connectivity. Conservatively `false` until the
    /// first real reading arrives.
    var isOnline: Bool { get }
    /// Invoked on the main actor whenever connectivity changes.
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    func start()
    func stop()
}
