#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import Foundation
#if canImport(Network)
import Network
#endif

/// What the device's network did, reduced to what matters to a live link.
public enum NetworkPathEvent: Equatable, Sendable {
    /// A usable network that differs from the last one: another interface
    /// (Wi-Fi to cellular), another Wi-Fi (a new gateway), or back from no
    /// network. The value describes the new path (for logs).
    case changed(String)
    /// No usable network (airplane mode, out of coverage).
    case lost
}

/// Turns raw path updates into ``NetworkPathEvent``s. A usable first update
/// is the starting point, not a change; an unusable one is `.lost` (a launch
/// with no network says so, CMUX-49). Repeats of the same path are dropped.
public struct NetworkPathFilter: Sendable {
    private var last: String?
    public private(set) var started = false
    public private(set) var down = false

    public init() {}

    /// The event for one update: whether the path is usable, and a
    /// description that differs whenever the route out does.
    public mutating func update(satisfied: Bool, signature: String) -> NetworkPathEvent? {
        defer { started = true }
        guard satisfied else {
            if down { return nil }
            down = true
            return .lost
        }
        let wasDown = down
        let previous = last
        down = false
        last = signature
        guard started, wasDown || previous != signature else { return nil }
        return .changed(signature)
    }

    /// The route out, the only thing a roam follows: the preferred interface (`availableInterfaces`
    /// is in order of preference) and the default route's gateways, sorted. A new Wi-Fi network
    /// keeps `en0` but changes the gateway; Wi-Fi to cellular changes the interface.
    ///
    /// Interfaces after the first are not the route: a USB link to the Mac (devicectl's CoreDevice
    /// tunnel on a phone plugged in), a dormant cellular context or a VPN's `utun` come and go
    /// under a healthy Wi-Fi. They were in the signature, so each one read as a new network and
    /// roamed every link: 183 roams in 20 minutes on a phone at a desk, each moving the WireGuard
    /// path from direct to none and back, kicking presence and re-asking the service for the Macs
    /// (a153, 2026-11-25).
    public static func signature(interfaces: [String], gateways: [String]) -> String {
        "\(interfaces.first ?? "") via \(gateways.sorted().joined(separator: ","))"
    }

    /// Classify the interface carrying the route. A phone can keep a cellular
    /// context available while Wi-Fi carries the route; treating that
    /// secondary interface as cellular needlessly caps Ultra Auto's repair
    /// budget and mislabels latency data.
    public static func networkKind(preferredCellular: Bool, preferredWiFi: Bool,
                                   preferredWired: Bool) -> String {
        if preferredCellular { return "lte" }
        if preferredWiFi { return "wifi" }
        if preferredWired { return "wired" }
        return "other"
    }
}

/// Holds a path change until the route has stayed put for ``window``. One weak Wi-Fi under a
/// cellular fallback flips the preferred interface en0 <-> pdp_ip0 several times a second: Leo's
/// phone logged 2,891 path changes in 15 minutes (11-27), and each one roamed every link, kicked
/// presence, re-asked the service for the Macs and restarted any dial under way (388 connections
/// in those 15 minutes). Now a burst is one change onto the path it ends on, and none when it
/// ends back on the path the links are already on. Losing the network and getting it back are
/// told at once: a redial after an outage must not wait.
public struct NetworkPathSettle: Sendable {
    /// How long the route must hold before the links move onto it.
    public static let window: TimeInterval = 1.5

    public enum Step: Equatable, Sendable {
        /// Deliver this event now.
        case deliver(NetworkPathEvent)
        /// Call ``settle(generation:)`` with this generation after ``window``.
        case arm(Int)
    }

    private var filter = NetworkPathFilter()
    /// The route the links are on (the first path, or the last change delivered).
    private var onPath: String?
    private var pending: String?
    private var generation = 0

    public init() {}

    public mutating func update(satisfied: Bool, signature: String) -> Step? {
        let first = !filter.started
        let wasDown = filter.down
        guard let event = filter.update(satisfied: satisfied, signature: signature) else {
            if first, satisfied { onPath = signature }
            return nil
        }
        generation += 1
        switch event {
        case .lost:
            pending = nil
            onPath = nil
            return .deliver(.lost)
        case .changed(let path):
            if wasDown {
                pending = nil
                onPath = path
                return .deliver(event)
            }
            pending = path
            return .arm(generation)
        }
    }

    /// The change to deliver once the route held for ``window`` since the update that armed
    /// `generation`; nil when a later update re-armed it or the burst ended on the links' path.
    public mutating func settle(generation armed: Int) -> NetworkPathEvent? {
        guard armed == generation, let path = pending else { return nil }
        pending = nil
        guard path != onPath else { return nil }
        onPath = path
        return .changed(path)
    }
}

#if canImport(Network)
/// Watches the device's network with `NWPathMonitor`.
public final class NetworkPathMonitor: @unchecked Sendable {
    public let events: AsyncStream<NetworkPathEvent>
    private let monitor = NWPathMonitor()

    public init() {
        let (events, continuation) = AsyncStream.makeStream(of: NetworkPathEvent.self, bufferingPolicy: .bufferingNewest(8))
        self.events = events
        // Updates and settles run on this one serial queue, so the state needs no lock.
        let state = FilterBox()
        let queue = DispatchQueue(label: "dev.cmux.mobile.network-path")
        monitor.pathUpdateHandler = { path in
            let preferred = path.availableInterfaces.first
            let kind = NetworkPathFilter.networkKind(
                preferredCellular: preferred?.type == .cellular,
                preferredWiFi: preferred?.type == .wifi,
                preferredWired: preferred?.type == .wiredEthernet)
            #if canImport(CmuxMobileLinkFFI)
            // The next WireGuard dial picks its ultra mode with it (Rust `ultra_for_dial`).
            setCellularPath(cellular: kind == "lte")
            // The key-to-paint histogram's network tag (Rust `key_paint`).
            setNetworkKind(kind: kind)
            #endif
            switch state.settle.update(satisfied: path.status == .satisfied, signature: Self.signature(path)) {
            case .deliver(let event): continuation.yield(event)
            case .arm(let generation):
                queue.asyncAfter(deadline: .now() + NetworkPathSettle.window) {
                    if let event = state.settle.settle(generation: generation) { continuation.yield(event) }
                }
            case nil: break
            }
        }
        let monitor = monitor
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    static func signature(_ path: NWPath) -> String {
        NetworkPathFilter.signature(interfaces: path.availableInterfaces.map(\.name), gateways: path.gateways.map { "\($0)" })
    }
}

private final class FilterBox: @unchecked Sendable {
    var settle = NetworkPathSettle()
}
#endif
