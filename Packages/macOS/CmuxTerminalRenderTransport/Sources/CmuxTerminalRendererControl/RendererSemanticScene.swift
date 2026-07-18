public import Foundation

/// One bounded opaque Ghostty semantic scene for an attached presentation.
public struct RendererSemanticScene: Equatable, Sendable {
    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Client-local presentation identity.
    public let presentationID: UUID

    /// Nonzero presentation lifetime receiving the scene.
    public let presentationGeneration: UInt64

    /// Canonical terminal revision represented by the scene.
    public let canonicalSequence: UInt64

    /// Presentation revision represented by the scene.
    public let presentationSequence: UInt64

    /// Opaque bytes produced and consumed by the versioned Ghostty scene ABI.
    public let bytes: Data

    /// Creates a validated semantic scene message.
    ///
    /// - Parameters:
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Nonzero presentation lifetime.
    ///   - canonicalSequence: Canonical terminal revision.
    ///   - presentationSequence: Presentation revision.
    ///   - bytes: Opaque Ghostty scene bytes, bounded to 64 MiB.
    /// - Throws: ``RendererControlError`` when an identity or size is invalid.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        canonicalSequence: UInt64,
        presentationSequence: UInt64,
        bytes: Data
    ) throws {
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        guard presentationGeneration != 0 else {
            throw RendererControlError.zeroPresentationGeneration
        }
        guard bytes.count <= RendererControlProtocol.maximumSemanticSceneLength else {
            throw RendererControlError.semanticSceneTooLarge
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.canonicalSequence = canonicalSequence
        self.presentationSequence = presentationSequence
        self.bytes = bytes
    }
}
