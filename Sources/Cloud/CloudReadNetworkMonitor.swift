import Foundation
@preconcurrency import Network

/// One path observer for the VM client. A Network.framework delivery queue
/// feeds an AsyncStream; it never protects domain state or runs UI work.
final class CloudReadNetworkMonitor: Sendable {
    private let monitor: NWPathMonitor
    let updates: AsyncStream<Bool>

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
    static let cmuxCloudReadNetworkRecovered = Notification.Name("cmux.cloud.readNetworkRecovered")
}
