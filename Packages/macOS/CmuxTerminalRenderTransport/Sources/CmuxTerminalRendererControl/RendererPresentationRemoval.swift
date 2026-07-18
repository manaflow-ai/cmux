public import Foundation

/// The exact terminal presentation lifetime to detach from a renderer worker.
public struct RendererPresentationRemoval: Equatable, Sendable {
    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Client-local presentation identity.
    public let presentationID: UUID

    /// Nonzero presentation lifetime being detached.
    public let presentationGeneration: UInt64

    /// Creates a validated presentation removal.
    ///
    /// - Parameters:
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Nonzero presentation lifetime being removed.
    /// - Throws: ``RendererControlError`` when an identity is zero.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64
    ) throws {
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        guard presentationGeneration != 0 else {
            throw RendererControlError.zeroPresentationGeneration
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
    }
}
