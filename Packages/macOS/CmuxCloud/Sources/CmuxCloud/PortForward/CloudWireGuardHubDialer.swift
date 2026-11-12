import Foundation

/// ``CloudHubDialing`` over the app's one ``CloudWireGuardHub``: each claim is
/// one hub lease, so the hub stays up exactly while forwarded connections are
/// live (plus its own idle grace).
public struct CloudWireGuardHubDialer: CloudHubDialing, Sendable {
    public init(
        hub: CloudWireGuardHub
    ) {
        self.hub = hub
    }

    public let hub: CloudWireGuardHub

    public func claimHubSocket() async throws -> CloudHubSocketClaim {
        try Task.checkCancellation()
        let claim = try await hub.acquire()
        if Task.isCancelled {
            await hub.release(claim.lease)
            throw CancellationError()
        }
        let hub = self.hub
        let lease = claim.lease
        return CloudHubSocketClaim(endpoint: .unix(path: claim.ready.socketPath)) {
            await hub.release(lease)
        }
    }
}
