import Foundation
@preconcurrency import Network

/// One path observer for the VM client. The actor owns the mutable
/// Network.framework monitor; only its sendable stream crosses the actor
/// boundary, and it never protects domain state or runs UI work.
actor CloudReadNetworkMonitor {
    private let monitor: NWPathMonitor
    nonisolated let updates: AsyncStream<Bool>

    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let (updates, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.updates = updates
        monitor.pathUpdateHandler = { continuation.yield($0.status != .unsatisfied) }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "cmux.cloud.read-network"))
    }

    deinit { monitor.cancel() }
}

extension Notification.Name {
    static let cmuxCloudReadNetworkChanged = Notification.Name("cmux.cloud.readNetworkChanged")
    static let cmuxCloudReadNetworkRecovered = Notification.Name("cmux.cloud.readNetworkRecovered")
}
