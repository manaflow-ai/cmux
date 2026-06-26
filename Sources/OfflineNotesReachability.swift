import Foundation
import Network

/// Observes whether the machine currently has network connectivity and reports
/// changes. Abstracted behind a protocol so the store can be driven by a fake
/// in tests instead of the real `NWPathMonitor`.
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

/// `NWPathMonitor`-backed reachability used in the running app.
@MainActor
final class OfflineNotesNetworkReachability: OfflineNotesReachabilityMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cmux.offline-notes.reachability")
    private var started = false
    private var hasDeliveredInitial = false

    /// Pessimistic until the monitor delivers its first path so we never claim
    /// online before it is proven.
    private(set) var isOnline: Bool = false
    var onChange: (@MainActor (Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isOnline != online || !self.hasDeliveredInitial
                self.isOnline = online
                self.hasDeliveredInitial = true
                if changed {
                    self.onChange?(online)
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
