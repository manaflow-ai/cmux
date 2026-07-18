public import Foundation

/// Launch identity the first daemon bootstrap must reproduce exactly.
public struct RendererWorkerExpectation: Equatable, Sendable {
    public let daemonInstanceID: UUID
    public let workspaceID: UUID
    public let rendererEpoch: UInt64

    public init(
        daemonInstanceID: UUID,
        workspaceID: UUID,
        rendererEpoch: UInt64
    ) {
        self.daemonInstanceID = daemonInstanceID
        self.workspaceID = workspaceID
        self.rendererEpoch = rendererEpoch
    }
}
