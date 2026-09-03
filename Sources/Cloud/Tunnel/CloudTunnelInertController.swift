import Foundation

/// The ``CloudTunnelControlling`` for the wg-quick backend: the coordinator
/// never calls it, and if something does, nothing happens. Keeps the
/// coordinator total without optionals in every method.
struct CloudTunnelInertController: CloudTunnelControlling {
    var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { $0.finish() }
    }

    func currentStatus() async -> CloudTunnelLinkStatus { .invalid }

    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {}

    func start() async throws {}

    func stop() async throws {}

    func remove() async throws {}

    nonisolated func stopForTermination() {}
}
