import Foundation
import Network

/// What the device's network did, reduced to what matters to a live link.
public enum NetworkPathEvent: Equatable, Sendable {
    /// A usable network that differs from the last one: another interface
    /// (Wi-Fi to cellular), another Wi-Fi (a new gateway), or back from no
    /// network. The value describes the new path (for logs).
    case changed(String)
    /// No usable network (airplane mode, out of coverage).
    case lost
}

/// Turns raw path updates into ``NetworkPathEvent``s. The first update is
/// the starting point, not a change; repeats of the same path are dropped.
public struct NetworkPathFilter: Sendable {
    private var last: String?
    private var started = false
    private var down = false

    public init() {}

    /// The event for one update: whether the path is usable, and a
    /// description that differs whenever the route out does.
    public mutating func update(satisfied: Bool, signature: String) -> NetworkPathEvent? {
        defer { started = true }
        guard satisfied else {
            if down { return nil }
            down = true
            return started ? .lost : nil
        }
        let wasDown = down
        let previous = last
        down = false
        last = signature
        guard started, wasDown || previous != signature else { return nil }
        return .changed(signature)
    }
}

/// Watches the device's network with `NWPathMonitor`.
public final class NetworkPathMonitor: @unchecked Sendable {
    public let events: AsyncStream<NetworkPathEvent>
    private let monitor = NWPathMonitor()

    public init() {
        let (events, continuation) = AsyncStream.makeStream(of: NetworkPathEvent.self, bufferingPolicy: .bufferingNewest(8))
        self.events = events
        // Updates arrive on this one serial queue, so the filter needs no lock.
        let state = FilterBox()
        monitor.pathUpdateHandler = { path in
            if let event = state.filter.update(satisfied: path.status == .satisfied, signature: Self.signature(path)) {
                continuation.yield(event)
            }
        }
        let monitor = monitor
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "dev.cmux.mobile.network-path"))
    }

    deinit {
        monitor.cancel()
    }

    /// The interfaces in order of preference and their gateways: a new
    /// Wi-Fi network keeps the interface (`en0`) but changes the gateway.
    static func signature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(interfaces) via \(gateways)"
    }
}

private final class FilterBox: @unchecked Sendable {
    var filter = NetworkPathFilter()
}
