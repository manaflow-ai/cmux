import Foundation

/// Supplies authorized Mac candidates; actual IROH admission establishes whether a Mac is reachable.
@MainActor
public protocol MobileIrohMacDiscovering: Sendable {
    /// Uses the current unexpired, permission-filtered directory, including a valid v2 cache.
    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac]
    /// Requests fresh metadata after an explicit user refresh or a failed route.
    func invalidateDiscovery(forMacDeviceID deviceID: String) async
    /// Emits only when directory content or account/team authority changes, never heartbeats.
    func directoryUpdates() -> AsyncStream<Void>
}

public extension MobileIrohMacDiscovering {
    func directoryUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
