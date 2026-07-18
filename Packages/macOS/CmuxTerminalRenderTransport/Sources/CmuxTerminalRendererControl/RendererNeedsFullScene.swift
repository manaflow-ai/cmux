public import Foundation

/// A worker request to replace one presentation's delta base with a full scene.
public struct RendererNeedsFullScene: Equatable, Sendable {
    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Client-local presentation identity.
    public let presentationID: UUID

    /// Nonzero presentation lifetime requesting a full scene.
    public let presentationGeneration: UInt64

    /// Last canonical sequence the worker applied successfully.
    public let lastCanonicalSequence: UInt64

    /// Last presentation sequence the worker applied successfully.
    public let lastPresentationSequence: UInt64

    /// Why the worker cannot continue from its current delta base.
    public let reason: RendererNeedsFullSceneReason

    /// Creates a validated full-scene request.
    ///
    /// - Parameters:
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Nonzero presentation lifetime.
    ///   - lastCanonicalSequence: Last applied canonical sequence.
    ///   - lastPresentationSequence: Last applied presentation sequence.
    ///   - reason: Reason a full scene is required.
    /// - Throws: ``RendererControlError`` when an identity is zero.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        lastCanonicalSequence: UInt64,
        lastPresentationSequence: UInt64,
        reason: RendererNeedsFullSceneReason
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
        self.lastCanonicalSequence = lastCanonicalSequence
        self.lastPresentationSequence = lastPresentationSequence
        self.reason = reason
    }
}
