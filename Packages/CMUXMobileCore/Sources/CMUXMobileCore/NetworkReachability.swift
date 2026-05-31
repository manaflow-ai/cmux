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

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.cmux.network-reachability", qos: .utility)

    /// Start monitoring immediately. Prefer ``shared`` over creating instances.
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
