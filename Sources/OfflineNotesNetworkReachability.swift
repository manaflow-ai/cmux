import Foundation
import Network

/// `NWPathMonitor`-backed ``OfflineNotesReachabilityMonitoring`` used in the
/// running app.
@MainActor
final class OfflineNotesNetworkReachability: OfflineNotesReachabilityMonitoring {
    // `var`, not `let`: an `NWPathMonitor` cannot be restarted after `cancel()`,
    // so a `stop()`/`start()` cycle must swap in a fresh monitor (see ``stop()``).
    private var monitor = NWPathMonitor()
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
        guard started else { return }
        monitor.cancel()
        // `cancel()` is terminal for an `NWPathMonitor`; reset our state and swap
        // in a fresh monitor so a later `start()` actually resumes monitoring
        // instead of no-op'ing on the `started` guard.
        started = false
        hasDeliveredInitial = false
        monitor = NWPathMonitor()
    }
}
