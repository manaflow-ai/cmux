public import Foundation

/// Exact acknowledgement that the host finished blitting one IOSurface frame.
public struct RendererControlFrameRelease: Equatable, Sendable {
    /// Identity of the cmuxd process lifetime that produced the scene.
    public let daemonInstanceID: UUID

    /// Nonzero identity of the renderer-worker lifetime that produced the frame.
    public let rendererEpoch: UInt64

    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Canonical terminal revision represented by the frame.
    public let terminalSequence: UInt64

    /// Client-local presentation identity.
    public let presentationID: UUID

    /// Nonzero presentation lifetime that produced the frame.
    public let presentationGeneration: UInt64

    /// Monotonic frame identity within the presentation generation.
    public let frameSequence: UInt64

    /// Kernel IOSurface identifier whose pool slot can now be reused.
    public let surfaceID: UInt32

    /// Creates a validated frame-release acknowledgement.
    ///
    /// - Parameters:
    ///   - daemonInstanceID: Identity of the producing cmuxd lifetime.
    ///   - rendererEpoch: Nonzero producing worker lifetime.
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - terminalSequence: Canonical revision represented by the frame.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Nonzero producing presentation lifetime.
    ///   - frameSequence: Frame sequence within that presentation lifetime.
    ///   - surfaceID: Kernel IOSurface identifier being released.
    /// - Throws: ``RendererControlError`` when an identity is zero.
    public init(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        terminalID: UUID,
        terminalEpoch: UInt64,
        terminalSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        frameSequence: UInt64,
        surfaceID: UInt32
    ) throws {
        try RendererControlValidation.validateIdentity(daemonInstanceID)
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        guard rendererEpoch != 0 else {
            throw RendererControlError.zeroRendererEpoch
        }
        guard presentationGeneration != 0 else {
            throw RendererControlError.zeroPresentationGeneration
        }
        self.daemonInstanceID = daemonInstanceID
        self.rendererEpoch = rendererEpoch
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.terminalSequence = terminalSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.frameSequence = frameSequence
        self.surfaceID = surfaceID
    }
}
