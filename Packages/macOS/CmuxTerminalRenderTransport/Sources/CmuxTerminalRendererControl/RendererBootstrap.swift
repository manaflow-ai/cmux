public import Foundation

/// The immutable daemon and workspace identity for one renderer-worker lifetime.
public struct RendererBootstrap: Equatable, Sendable {
    /// Identity of the cmuxd process lifetime.
    public let daemonInstanceID: UUID

    /// Stable identity of the workspace rendered by this worker.
    public let workspaceID: UUID

    /// Nonzero identity of this disposable renderer-worker lifetime.
    public let rendererEpoch: UInt64

    /// Creates validated renderer bootstrap state.
    ///
    /// - Parameters:
    ///   - daemonInstanceID: Identity of the cmuxd process lifetime.
    ///   - workspaceID: Stable identity of the rendered workspace.
    ///   - rendererEpoch: Nonzero worker-lifetime identity.
    /// - Throws: ``RendererControlError`` when an identity is zero.
    public init(daemonInstanceID: UUID, workspaceID: UUID, rendererEpoch: UInt64) throws {
        guard daemonInstanceID != RendererControlValidation.zeroUUID,
              workspaceID != RendererControlValidation.zeroUUID else {
            throw RendererControlError.zeroIdentity
        }
        guard rendererEpoch != 0 else {
            throw RendererControlError.zeroRendererEpoch
        }
        self.daemonInstanceID = daemonInstanceID
        self.workspaceID = workspaceID
        self.rendererEpoch = rendererEpoch
    }
}
