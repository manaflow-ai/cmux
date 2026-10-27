#if canImport(Network)
import Network

/// Network state from `NWPathMonitor`: a path is usable when it is satisfied,
/// and for a background prefetch also neither constrained (Low Data Mode) nor
/// expensive (a phone hotspot, cellular).
public struct PathMonitorChromiumRuntimeNetwork: ChromiumRuntimeNetwork {
    /// Creates the network observer (each call starts and stops its own monitor).
    public init() {}

    public func isUsable(allowsExpensive: Bool) async -> Bool {
        for await path in NWPathMonitor() {
            return Self.isUsable(path, allowsExpensive: allowsExpensive)
        }
        return false
    }

    public func waitUntilUsable(allowsExpensive: Bool) async throws {
        for await path in NWPathMonitor() {
            try Task.checkCancellation()
            if Self.isUsable(path, allowsExpensive: allowsExpensive) { return }
        }
        try Task.checkCancellation()
    }

    static func isUsable(_ path: NWPath, allowsExpensive: Bool) -> Bool {
        guard path.status == .satisfied else { return false }
        return allowsExpensive || (!path.isExpensive && !path.isConstrained)
    }
}
#endif
