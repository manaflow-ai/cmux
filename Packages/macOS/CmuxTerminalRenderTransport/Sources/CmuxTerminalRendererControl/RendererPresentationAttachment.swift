public import CmuxTerminalRenderProtocol
public import Foundation

/// Render-affecting state that attaches one terminal presentation to a worker.
public struct RendererPresentationAttachment: Equatable, Sendable {
    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Client-local presentation identity.
    public let presentationID: UUID

    /// Nonzero presentation lifetime for size, scale, and configuration.
    public let presentationGeneration: UInt64

    /// IOSurface width in physical pixels.
    public let width: UInt32

    /// IOSurface height in physical pixels.
    public let height: UInt32

    /// Number of physical pixels per logical point.
    public let backingScaleFactor: Double

    /// IOSurface pixel layout.
    public let pixelFormat: TerminalRenderPixelFormat

    /// Color-space semantics used to render the pixels.
    public let colorSpace: TerminalRenderColorSpace

    /// Private Mach endpoint used to publish completed frames to the host.
    public let frameEndpoint: TerminalRenderFrameEndpoint

    /// Monotonic revision of the resolved render configuration.
    public let resolvedConfigRevision: UInt64

    /// Opaque resolved Ghostty renderer configuration, never raw user config text.
    public let resolvedConfig: Data

    /// Creates a validated presentation attachment.
    ///
    /// - Parameters:
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Nonzero presentation lifetime.
    ///   - width: IOSurface width in physical pixels.
    ///   - height: IOSurface height in physical pixels.
    ///   - backingScaleFactor: Physical pixels per logical point.
    ///   - pixelFormat: IOSurface pixel layout.
    ///   - colorSpace: Frame color-space semantics.
    ///   - frameEndpoint: Authenticated frame-plane endpoint.
    ///   - resolvedConfigRevision: Revision of the resolved render config.
    ///   - resolvedConfig: Opaque resolved render config bytes.
    /// - Throws: ``RendererControlError`` when a field violates protocol bounds.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        width: UInt32,
        height: UInt32,
        backingScaleFactor: Double,
        pixelFormat: TerminalRenderPixelFormat,
        colorSpace: TerminalRenderColorSpace,
        frameEndpoint: TerminalRenderFrameEndpoint,
        resolvedConfigRevision: UInt64,
        resolvedConfig: Data
    ) throws {
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        guard presentationGeneration != 0 else {
            throw RendererControlError.zeroPresentationGeneration
        }
        try RendererControlValidation.validateDimensions(width: width, height: height)
        try RendererControlValidation.validateScale(backingScaleFactor)
        guard resolvedConfig.count <= RendererControlProtocol.maximumResolvedConfigLength else {
            throw RendererControlError.resolvedConfigTooLarge
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.width = width
        self.height = height
        self.backingScaleFactor = backingScaleFactor
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.frameEndpoint = frameEndpoint
        self.resolvedConfigRevision = resolvedConfigRevision
        self.resolvedConfig = resolvedConfig
    }
}
