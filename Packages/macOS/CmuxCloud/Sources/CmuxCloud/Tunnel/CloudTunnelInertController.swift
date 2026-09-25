import Foundation

/// The ``CloudTunnelControlling`` for a build without Network Extension support: the coordinator
/// never calls it, and if something does, nothing happens. Keeps the
/// coordinator total without optionals in every method.
public struct CloudTunnelInertController: CloudTunnelControlling, Sendable {
    public var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { $0.finish() }
    }

    public func currentStatus() async -> CloudTunnelLinkStatus { .invalid }

    public func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {}

    public func start() async throws {}

    public func stop() async throws {}

    public func remove() async throws {}

    public nonisolated func stopForTermination() {}
}
