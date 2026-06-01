import Foundation
import Network
import Observation

/// Observable network-reachability state backed by `NWPathMonitor`.
///
/// Use it to gate network operations (for example, sign-in) so the UI can give
/// immediate offline feedback instead of waiting for a request to time out.
/// The published ``isOnline`` flag starts optimistically `true` and updates as
/// soon as the first path is delivered.
///
/// ```swift
/// guard NetworkReachability.shared.isOnline else { throw AuthError.offline }
/// ```
@MainActor
@Observable
public final class NetworkReachability {
    /// Process-wide reachability monitor.
    public static let shared = NetworkReachability()

    /// Whether the system currently has a satisfied network path.
    public private(set) var isOnline: Bool = true

    /// Convenience inverse of ``isOnline``.
    public var isOffline: Bool { !isOnline }

    /// Monotonic counter that increments on a *meaningful* path change: the path
    /// regaining a satisfied state after being offline, or the primary interface
    /// type switching (for example Wi-Fi to cellular) while online.
    ///
    /// Observe this to drive reconnect/resync when the underlying network moves
    /// out from under a live connection. It deliberately does not bump on the
    /// first path delivery, so observers don't recover spuriously at startup.
    public private(set) var pathChangeGeneration: Int = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.cmux.network-reachability", qos: .utility)
    private var lastInterfaceType: NWInterface.InterfaceType?

    /// Start monitoring immediately. Prefer ``shared`` over creating instances.
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Compute Sendable values on the monitor queue; never capture NWPath.
            let online = path.status == .satisfied
            let primaryType = NetworkReachability.primaryInterfaceType(of: path)
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                let previousType = self.lastInterfaceType
                self.isOnline = online
                if online { self.lastInterfaceType = primaryType }
                let regainedOnline = online && !wasOnline
                let interfaceChanged = online && previousType != nil && primaryType != previousType
                if regainedOnline || interfaceChanged {
                    self.pathChangeGeneration &+= 1
                }
            }
        }
        monitor.start(queue: queue)
    }

    private nonisolated static func primaryInterfaceType(of path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular]
        where path.usesInterfaceType(type) {
            return type
        }
        return path.availableInterfaces.first?.type
    }

    deinit {
        monitor.cancel()
    }
}
